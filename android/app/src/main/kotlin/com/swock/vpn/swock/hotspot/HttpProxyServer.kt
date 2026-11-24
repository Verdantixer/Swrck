package com.swock.vpn.swock.hotspot

import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong

/** HTTP/HTTPS (CONNECT) proxy bound only to the hotspot interface address. */
class HttpProxyServer(
    private val bindAddress: InetAddress,
    private val port: Int,
    private val connectUpstream: (host: String, port: Int) -> Socket,
    private val onLog: (String) -> Unit,
) {
    private val executor: ExecutorService = Executors.newCachedThreadPool()
    private val permits = Semaphore(MAX_CONNECTIONS)
    private val open = ConcurrentHashMap.newKeySet<Socket>()
    private val transferred = AtomicLong(0)
    @Volatile private var server: ServerSocket? = null

    val bytesTransferred: Long get() = transferred.get()
    val localPort: Int get() = server?.localPort ?: 0

    fun start() {
        val socket = ServerSocket()
        try {
            socket.reuseAddress = true
            socket.bind(InetSocketAddress(bindAddress, port), 50)
        } catch (error: IOException) {
            socket.close()
            executor.shutdownNow()
            throw error
        }
        server = socket
        Thread({ acceptLoop(socket) }, "swock-proxy-accept").start()
    }

    fun stop() {
        try { server?.close() } catch (_: IOException) { }
        server = null
        open.forEach(::closeQuietly)
        open.clear()
        executor.shutdownNow()
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val client = try { socket.accept() } catch (_: IOException) { break }
            if (!permits.tryAcquire()) {
                closeQuietly(client)
                continue
            }
            open.add(client)
            try {
                executor.execute {
                    try { handle(client) } finally {
                        permits.release()
                        open.remove(client)
                        closeQuietly(client)
                    }
                }
            } catch (_: RejectedExecutionException) {
                permits.release()
                open.remove(client)
                closeQuietly(client)
                break
            }
        }
    }

    private fun handle(client: Socket) {
        client.tcpNoDelay = true
        client.soTimeout = HEADER_TIMEOUT_MS
        val input = BufferedInputStream(client.getInputStream(), 8192)
        val output = client.getOutputStream()
        val header: String? = try { readHeader(input) } catch (_: IOException) { return }
        if (header == null) {
            respond(output, 400, "Bad Request")
            return
        }
        val lines = header.split("\r\n").filter { it.isNotEmpty() }
        val parts = lines.firstOrNull()?.split(" ")
        if (parts == null || parts.size != 3) {
            respond(output, 400, "Bad Request")
            return
        }
        val method = parts[0]
        val target = parts[1]
        val version = parts[2]
        try {
            if (method.equals("CONNECT", ignoreCase = true)) {
                val (host, targetPort) = splitHostPort(target, 443)
                val upstream = openUpstream(output, host, targetPort) ?: return
                output.write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
                output.flush()
                relay(client, input, output, upstream)
            } else if (target.startsWith("http://", ignoreCase = true)) {
                val rest = target.substring(7)
                val slash = rest.indexOf('/')
                val authority = (if (slash >= 0) rest.substring(0, slash) else rest).substringAfterLast('@')
                val path = if (slash >= 0) rest.substring(slash) else "/"
                val (host, targetPort) = splitHostPort(authority, 80)
                val upstream = openUpstream(output, host, targetPort) ?: return
                val forwarded = StringBuilder("$method $path $version\r\n")
                for (line in lines.drop(1)) {
                    val name = line.substringBefore(':').trim().lowercase()
                    if (name in HOP_HEADERS) continue
                    forwarded.append(line).append("\r\n")
                }
                forwarded.append("Connection: close\r\n\r\n")
                upstream.getOutputStream().write(forwarded.toString().toByteArray(Charsets.ISO_8859_1))
                relay(client, input, output, upstream)
            } else {
                respond(output, 400, "Bad Request")
            }
        } catch (_: IllegalArgumentException) {
            respond(output, 400, "Bad Request")
        } catch (_: IOException) {
            // Client or upstream closed the connection.
        }
    }

    private fun openUpstream(output: OutputStream, host: String, targetPort: Int): Socket? =
        try {
            connectUpstream(host, targetPort).also { open.add(it) }
        } catch (error: IOException) {
            onLog("Proxy refused $host:$targetPort: ${error.message}")
            val vpnDown = error.message?.contains("VPN") == true
            respond(output, if (vpnDown) 503 else 502, if (vpnDown) "VPN Unavailable" else "Bad Gateway")
            null
        }

    private fun relay(client: Socket, clientIn: InputStream, clientOut: OutputStream, upstream: Socket) {
        client.soTimeout = RELAY_TIMEOUT_MS
        upstream.soTimeout = RELAY_TIMEOUT_MS
        val downstream = executor.submit {
            try { copy(upstream.getInputStream(), clientOut) } catch (_: IOException) { } finally {
                closeQuietly(client)
                closeQuietly(upstream)
            }
        }
        try {
            copy(clientIn, upstream.getOutputStream())
            try { upstream.shutdownOutput() } catch (_: IOException) { }
        } catch (_: IOException) {
            closeQuietly(upstream)
            closeQuietly(client)
        }
        try { downstream.get() } catch (_: Exception) { }
        open.remove(upstream)
        closeQuietly(upstream)
    }

    private fun copy(source: InputStream, sink: OutputStream) {
        val buffer = ByteArray(16 * 1024)
        while (true) {
            val read = source.read(buffer)
            if (read < 0) return
            sink.write(buffer, 0, read)
            sink.flush()
            transferred.addAndGet(read.toLong())
        }
    }

    private fun readHeader(input: InputStream): String? {
        val buffer = ByteArrayOutputStream()
        var matched = 0
        while (buffer.size() < MAX_HEADER_BYTES) {
            val next = input.read()
            if (next < 0) return null
            buffer.write(next)
            matched = when {
                next == '\r'.code && (matched == 0 || matched == 2) -> matched + 1
                next == '\n'.code && (matched == 1 || matched == 3) -> matched + 1
                next == '\r'.code -> 1
                else -> 0
            }
            if (matched == 4) return buffer.toString(Charsets.ISO_8859_1.name()).removeSuffix("\r\n\r\n")
        }
        return null
    }

    private fun splitHostPort(value: String, defaultPort: Int): Pair<String, Int> {
        if (value.startsWith("[")) {
            val end = value.indexOf(']')
            require(end > 0)
            val port = value.substring(end + 1).removePrefix(":").ifEmpty { null }?.toInt() ?: defaultPort
            require(port in 1..65535)
            return value.substring(1, end) to port
        }
        val colon = value.lastIndexOf(':')
        if (colon < 0) {
            require(value.isNotEmpty())
            return Pair(value, defaultPort)
        }
        val host = value.substring(0, colon)
        val port = value.substring(colon + 1).toInt()
        require(host.isNotEmpty() && port in 1..65535)
        return host to port
    }

    private fun respond(output: OutputStream, code: Int, reason: String) {
        try {
            output.write("HTTP/1.1 $code $reason\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            output.flush()
        } catch (_: IOException) { }
    }

    private fun closeQuietly(socket: Socket) {
        try { socket.close() } catch (_: IOException) { }
    }

    private companion object {
        const val MAX_CONNECTIONS = 96
        const val MAX_HEADER_BYTES = 16 * 1024
        const val HEADER_TIMEOUT_MS = 15_000
        const val RELAY_TIMEOUT_MS = 300_000
        val HOP_HEADERS = setOf("proxy-connection", "proxy-authorization", "connection", "keep-alive")
    }
}
