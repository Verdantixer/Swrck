package com.swock.vpn.swock.networking

import android.net.Network
import android.net.VpnService
import android.os.ParcelFileDescriptor
import android.util.Base64
import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.HostKey
import com.jcraft.jsch.HostKeyRepository
import com.jcraft.jsch.JSch
import com.jcraft.jsch.Session
import com.jcraft.jsch.SocketFactory
import org.json.JSONObject
import java.io.IOException
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ThreadLocalRandom
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLSocket
import javax.net.ssl.SSLSocketFactory

private const val SSH_PAYLOAD_DELAY_SPLIT_MS = 1_000L

/** Full-device SSH tunnel using local SOCKS5 and standard SSH direct-tcpip channels. */
class SshVpnEngine(
    private val vpnService: VpnService,
    private val underlyingNetwork: () -> Network?,
    private val onStatus: (String, String) -> Unit = { _, _ -> },
    private val onLog: (String) -> Unit = {},
) : VpnEngine {
    @Volatile private var state = "disconnected"
    @Volatile private var message = "Disconnected"
    @Volatile private var session: Session? = null
    @Volatile private var udpGatewayChannel: ChannelDirectTCPIP? = null
    @Volatile private var udpGateway: SshUdpGateway? = null
    @Volatile private var socksProxy: SshLocalSocksProxy? = null
    @Volatile private var tunBridge: Tun2SocksBridge? = null
    private val stopped = AtomicBoolean(true)
    private val uploadBytes = AtomicLong(0)
    private val downloadBytes = AtomicLong(0)

    override fun start(profileJson: String, tun: ParcelFileDescriptor) {
        val profile = JSONObject(profileJson)
        val config = profile.optJSONObject("ssh") ?: JSONObject()
        val validation = validate(profile, config)
        require(validation == null) { validation ?: "Invalid SSH profile" }
        stopped.set(false)
        setStatus("connecting", "Connecting to SSH server")
        try {
            val jsch = JSch()
            if (config.optString("authentication", "password") == "privateKey") {
                val key = config.optString("privateKey").toByteArray(StandardCharsets.UTF_8)
                val passphrase = config.optString("privateKeyPassphrase")
                    .takeIf { it.isNotEmpty() }
                    ?.toByteArray(StandardCharsets.UTF_8)
                jsch.addIdentity("swock-profile-key", key, null, passphrase)
            }
            val host = profile.optString("server").trim()
            val port = profile.optInt("port")
            val sshSession = jsch.getSession(config.optString("username"), host, port)
            if (config.optString("authentication", "password") == "password") {
                sshSession.setPassword(profile.optString("password"))
            }
            val expectedFingerprint = config.optString("hostKeyFingerprint").trim()
            sshSession.setConfig(
                "StrictHostKeyChecking",
                if (expectedFingerprint.isEmpty()) "no" else "yes",
            )
            sshSession.setHostKeyRepository(PinnedHostKeyRepository(expectedFingerprint))
            sshSession.setSocketFactory(
                ProtectedSshSocketFactory(
                    vpnService = vpnService,
                    underlyingNetwork = underlyingNetwork,
                    destinationHost = host,
                    destinationPort = port,
                    config = config,
                    onLog = onLog,
                ),
            )
            sshSession.setServerAliveInterval(15_000)
            sshSession.setServerAliveCountMax(3)
            sshSession.connect(30_000)
            session = sshSession
            val advanced = AdvancedOptions.from(profile)
            var gateway: SshUdpGateway? = null
            if (advanced.udpGatewayEnabled) {
                val gatewayChannel = sshSession.openChannel("direct-tcpip") as ChannelDirectTCPIP
                gatewayChannel.setHost("127.0.0.1")
                gatewayChannel.setPort(advanced.udpGatewayPort)
                gatewayChannel.setOrgIPAddress(host)
                gatewayChannel.setOrgPort(port)
                gatewayChannel.connect(15_000)
                udpGatewayChannel = gatewayChannel
                gateway = SshUdpGateway(
                    input = gatewayChannel.inputStream,
                    output = gatewayChannel.outputStream,
                    onTunPacket = { packet -> socksProxy?.routeUdpResponse(packet) },
                    onFailure = { reason -> fail("SSH UDP gateway failed: $reason") },
                    onUpload = { uploadBytes.addAndGet(it.toLong()) },
                    onDownload = { downloadBytes.addAndGet(it.toLong()) },
                )
                udpGateway = gateway
                onLog("SSH UDP gateway active on port ${advanced.udpGatewayPort}")
            }
            check(!stopped.get()) { "SSH session stopped during startup." }
            val proxy = SshLocalSocksProxy(
                session = sshSession,
                udpGateway = gateway,
                onLog = onLog,
                onFailure = ::fail,
                onUpload = { uploadBytes.addAndGet(it.toLong()) },
                onDownload = { downloadBytes.addAndGet(it.toLong()) },
            )
            socksProxy = proxy
            proxy.start()
            val bridge = Tun2SocksBridge(
                context = vpnService,
                tun = tun,
                mtu = config.optInt("mtu", 1400),
                socksPort = proxy.port,
                onLog = onLog,
                enableUdpRelay = true,
                enableIpv6 = AdvancedOptions.from(profile).ipv6Enabled,
            )
            tunBridge = bridge
            bridge.start()
            check(!stopped.get()) { "SSH session stopped during startup." }
            setStatus("connected", "SSH tunnel connected")
            onLog("SSH host key verified; full-device SSH tunnel is active")
            if (!advanced.udpGatewayEnabled) {
                onLog("SSH DNS uses TCP; enable the SSH UDP Gateway for other UDP traffic")
            }
            Thread({ monitorTunnel(sshSession, bridge) }, "ssh-tunnel-monitor")
                .apply { isDaemon = true; start() }
        } catch (error: Exception) {
            stop()
            setStatus("error", error.message?.takeIf { it.isNotBlank() } ?: "SSH tunnel startup failed")
            throw error
        } catch (error: LinkageError) {
            // Keep an unavailable platform/JSch class from terminating the VPN service
            // process. Surface it through the normal connection error and cleanup path.
            stop()
            val failure = IllegalStateException(
                "SSH runtime could not load a required Android or SSH component (${error.javaClass.simpleName}).",
                error,
            )
            setStatus("error", failure.message ?: "SSH runtime component is unavailable.")
            throw failure
        }
    }

    private fun monitorTunnel(sshSession: Session, bridge: Tun2SocksBridge) {
        while (!stopped.get()) {
            if (!sshSession.isConnected) {
                fail("SSH server disconnected")
                return
            }
            if (!bridge.isAlive()) {
                fail("Local SSH TUN bridge stopped unexpectedly")
                return
            }
            try {
                Thread.sleep(500)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                return
            }
        }
    }

    private fun fail(reason: String) {
        if (stopped.compareAndSet(false, true)) {
            setStatus("error", reason)
            closeResources()
        }
    }

    override fun stop() {
        stopped.set(true)
        closeResources()
        setStatus("disconnected", "Disconnected")
    }

    private fun closeResources() {
        try { tunBridge?.stop() } catch (_: Exception) {}
        tunBridge = null
        try { socksProxy?.close() } catch (_: Exception) {}
        socksProxy = null
        try { udpGateway?.close() } catch (_: Exception) {}
        udpGateway = null
        try { udpGatewayChannel?.disconnect() } catch (_: Exception) {}
        udpGatewayChannel = null
        try { session?.disconnect() } catch (_: Exception) {}
        session = null
    }

    override fun getStatus(): Map<String, Any?> = mapOf(
        "state" to state,
        "connected" to (state == "connected"),
        "message" to message,
    )

    override fun getStatistics(): Map<String, Any?> = mapOf(
        "uploadBytes" to uploadBytes.get(),
        "downloadBytes" to downloadBytes.get(),
    )

    override fun testConnection(profileJson: String): Boolean =
        validate(JSONObject(profileJson), JSONObject(profileJson).optJSONObject("ssh") ?: JSONObject()) == null

    private fun setStatus(next: String, text: String) {
        state = next
        message = text
        onStatus(next, text)
    }

    companion object {
        fun validateConfig(profileJson: String): String? = try {
            val profile = JSONObject(profileJson)
            validate(profile, profile.optJSONObject("ssh") ?: JSONObject())
        } catch (_: Exception) {
            "SSH profile data could not be read."
        }

        private fun validate(profile: JSONObject, config: JSONObject): String? {
            val host = profile.optString("server").trim()
            val port = profile.optInt("port")
            val username = config.optString("username").trim()
            val authentication = config.optString("authentication", "password")
            val fingerprint = config.optString("hostKeyFingerprint").trim()
            val proxyEnabled = config.optBoolean("proxyEnabled")
            return when {
                host.isBlank() -> "SSH server address is required."
                port !in 1..65535 -> "SSH server port must be between 1 and 65535."
                username.isBlank() -> "SSH username is required."
                authentication == "password" && profile.optString("password").isBlank() -> "SSH password is required."
                authentication == "privateKey" && config.optString("privateKey").isBlank() -> "SSH private key is required."
                authentication !in setOf("password", "privateKey") -> "Unsupported SSH authentication method."
                fingerprint.isNotEmpty() && !fingerprint.startsWith("SHA256:") -> "Enter a SHA-256 fingerprint beginning with SHA256:, or leave it blank."
                config.optInt("mtu", 1400) !in 576..9000 -> "SSH tunnel MTU must be between 576 and 9000."
                proxyEnabled && config.optString("proxyHost").isBlank() -> "Proxy host is required when proxy mode is enabled."
                proxyEnabled && config.optInt("proxyPort", 0) !in 1..65535 -> "Proxy port must be between 1 and 65535."
                config.optBoolean("tlsEnabled") && config.optString("sni").isBlank() -> "TLS SNI is required when the TLS wrapper is enabled."
                config.optBoolean("payloadEnabled") && config.optString("payload").isBlank() -> "Payload is required when payload mode is enabled."
                config.optBoolean("payloadEnabled") && proxyEnabled && config.optString("proxyType") != "http" -> "Custom payloads require an HTTP CONNECT proxy."
                else -> null
            }
        }

    }
}

private class PinnedHostKeyRepository(private val expectedFingerprint: String) : HostKeyRepository {
    override fun check(host: String, key: ByteArray): Int {
        if (expectedFingerprint.isEmpty()) return HostKeyRepository.NOT_INCLUDED
        val digest = MessageDigest.getInstance("SHA-256").digest(key)
        val actual = "SHA256:" + Base64.encodeToString(digest, Base64.NO_WRAP).trimEnd('=')
        return if (actual == expectedFingerprint.trim()) {
            HostKeyRepository.OK
        } else {
            HostKeyRepository.CHANGED
        }
    }

    override fun add(hostkey: HostKey, ui: com.jcraft.jsch.UserInfo?) = Unit
    override fun remove(host: String, type: String) = Unit
    override fun remove(host: String, type: String, key: ByteArray) = Unit
    override fun getHostKey(): Array<HostKey> = emptyArray()
    override fun getHostKey(host: String, type: String): Array<HostKey> = emptyArray()
    override fun getKnownHostsRepositoryID(): String = "profile SHA-256 pin"
}

private class ProtectedSshSocketFactory(
    private val vpnService: VpnService,
    private val underlyingNetwork: () -> Network?,
    private val destinationHost: String,
    private val destinationPort: Int,
    private val config: JSONObject,
    private val onLog: (String) -> Unit,
) : SocketFactory {
    private val rotationIndexes = ConcurrentHashMap<String, AtomicInteger>()

    override fun createSocket(host: String, port: Int): Socket {
        val proxyEnabled = config.optBoolean("proxyEnabled")
        val connectHost = if (proxyEnabled) config.optString("proxyHost") else host
        val connectPort = if (proxyEnabled) config.optInt("proxyPort", 0) else port
        val network = underlyingNetwork()
        val addresses = try {
            if (network != null) network.getAllByName(connectHost)
            else InetAddress.getAllByName(connectHost)
        } catch (error: Exception) {
            throw IOException("Could not resolve SSH transport host on the active network: ${error.message}", error)
        }
        if (addresses.isEmpty()) throw IOException("No IP addresses are available for SSH transport host: $connectHost")

        var raw: Socket? = null
        var lastError: IOException? = null
        for (address in addresses) {
            val candidate = Socket()
            try {
                check(vpnService.protect(candidate)) { "Could not protect SSH socket from the VPN tunnel." }
                network?.bindSocket(candidate)
                candidate.connect(InetSocketAddress(address, connectPort), 10_000)
                raw = candidate
                if (addresses.size > 1) onLog("Connected to SSH transport via ${address.hostAddress}")
                break
            } catch (error: Exception) {
                try {
                    candidate.close()
                } catch (closeError: Exception) {
                    error.addSuppressed(closeError)
                }
                lastError = IOException(
                    "SSH transport connection via ${address.hostAddress} failed: ${error.message}",
                    error,
                )
                onLog(lastError.message ?: "SSH transport connection attempt failed")
            }
        }
        val connectedSocket = raw ?: throw IOException(
            "Could not connect to SSH transport host $connectHost using any resolved IP address.",
            lastError,
        )
        connectedSocket.soTimeout = 15_000

        if (proxyEnabled) {
            when (config.optString("proxyType", "http")) {
                "http" -> establishHttpConnect(connectedSocket)
                "socks5" -> establishSocks5(connectedSocket)
                else -> throw IOException("Unsupported upstream proxy type.")
            }
        }

        val tunnel = if (config.optBoolean("tlsEnabled")) wrapTls(connectedSocket) else connectedSocket
        if (config.optBoolean("payloadEnabled") && !proxyEnabled) {
            sendPayload(tunnel, awaitHttpResponse = true)
        }
        return tunnel
    }

    private fun establishHttpConnect(socket: Socket) {
        val output = socket.getOutputStream()
        if (config.optBoolean("payloadEnabled")) {
            sendPayload(socket, awaitHttpResponse = false)
        } else {
            val authority = "$destinationHost:$destinationPort"
            val request = buildString {
                append("CONNECT $authority HTTP/1.1\r\nHost: $authority\r\n")
                val user = config.optString("proxyUsername")
                if (user.isNotEmpty()) {
                    val credentials = "$user:${config.optString("proxyPassword")}".toByteArray()
                    append("Proxy-Authorization: Basic ")
                    append(Base64.encodeToString(credentials, Base64.NO_WRAP))
                    append("\r\n")
                }
                append("Connection: keep-alive\r\n\r\n")
            }
            output.write(request.toByteArray(StandardCharsets.ISO_8859_1))
            output.flush()
        }
        val response = readHttpHeaders(socket)
        require(Regex("^HTTP/\\d(?:\\.\\d)? 2\\d\\d(?: |$)").containsMatchIn(response)) {
            "HTTP proxy refused SSH CONNECT: ${response.lineSequence().firstOrNull().orEmpty()}"
        }
    }

    private fun establishSocks5(socket: Socket) {
        val input = socket.getInputStream()
        val output = socket.getOutputStream()
        val user = config.optString("proxyUsername")
        output.write(if (user.isBlank()) byteArrayOf(5, 1, 0) else byteArrayOf(5, 2, 0, 2))
        output.flush()
        val version = input.read()
        val method = input.read()
        require(version == 5 && method != 0xff && method >= 0) { "SOCKS5 proxy authentication negotiation failed." }
        if (method == 2) {
            val userBytes = user.toByteArray(StandardCharsets.UTF_8)
            val passwordBytes = config.optString("proxyPassword").toByteArray(StandardCharsets.UTF_8)
            require(userBytes.size in 1..255 && passwordBytes.size <= 255) { "SOCKS5 credentials are too long." }
            output.write(byteArrayOf(1, userBytes.size.toByte()) + userBytes + byteArrayOf(passwordBytes.size.toByte()) + passwordBytes)
            output.flush()
            require(input.read() == 1 && input.read() == 0) { "SOCKS5 proxy authentication failed." }
        } else {
            require(method == 0) { "SOCKS5 proxy selected an unsupported authentication method." }
        }
        val hostBytes = destinationHost.toByteArray(StandardCharsets.UTF_8)
        require(hostBytes.size <= 255) { "SSH host name is too long for SOCKS5." }
        output.write(byteArrayOf(5, 1, 0, 3, hostBytes.size.toByte()) + hostBytes + byteArrayOf((destinationPort shr 8).toByte(), destinationPort.toByte()))
        output.flush()
        require(input.read() == 5) { "SOCKS5 proxy connection failed." }
        val result = input.read()
        require(result == 0) { "SOCKS5 proxy refused the SSH connection (code $result)." }
        input.read() // reserved
        when (input.read()) {
            1 -> skipFully(input, 4)
            3 -> skipFully(input, input.read())
            4 -> skipFully(input, 16)
            else -> throw IOException("SOCKS5 proxy returned an invalid address type.")
        }
        skipFully(input, 2)
    }

    private fun skipFully(input: java.io.InputStream, count: Int) {
        require(count >= 0) { "SOCKS5 proxy returned a truncated address." }
        var remaining = count
        while (remaining > 0) {
            val skipped = input.skip(remaining.toLong()).toInt()
            if (skipped > 0) remaining -= skipped
            else if (input.read() < 0) throw IOException("SOCKS5 proxy returned a truncated address.")
            else remaining--
        }
    }

    private fun sendPayload(socket: Socket, awaitHttpResponse: Boolean) {
        val payload = formatPayload(config.optString("payload"))
        val output = socket.getOutputStream()
        val delayedChunks = payload.split("[delay_split]", ignoreCase = true)
        delayedChunks.forEachIndexed { delayedIndex, delayedChunk ->
            delayedChunk.split("[split]", ignoreCase = true).forEach { chunk ->
                if (chunk.isNotEmpty()) {
                    output.write(chunk.toByteArray(StandardCharsets.ISO_8859_1))
                    output.flush()
                }
            }
            if (delayedIndex < delayedChunks.lastIndex) {
                try {
                    Thread.sleep(SSH_PAYLOAD_DELAY_SPLIT_MS)
                } catch (error: InterruptedException) {
                    Thread.currentThread().interrupt()
                    throw IOException("SSH payload split was interrupted.", error)
                }
            }
        }
        if (awaitHttpResponse) {
            val response = readHttpHeaders(socket)
            require(Regex("^HTTP/\\d(?:\\.\\d)? 2\\d\\d(?: |$)").containsMatchIn(response)) {
                "Payload endpoint did not establish a tunnel: ${response.lineSequence().firstOrNull().orEmpty()}"
            }
        }
    }

    private fun formatPayload(template: String): String {
        val hostPort = "$destinationHost:$destinationPort"
        val replacements = mapOf(
            "[method]" to "CONNECT",
            "[host]" to destinationHost,
            "[port]" to destinationPort.toString(),
            "[host_port]" to hostPort,
            "[ssh]" to hostPort,
            "[protocol]" to "HTTP/1.0",
            "[crlf]" to "\r\n",
            "[cr]" to "\r",
            "[lf]" to "\n",
            "[lfcr]" to "\n\r",
            "[ua]" to System.getProperty("http.agent").orEmpty(),
            "\\r" to "\r",
            "\\n" to "\n",
        )
        var payload = template
        for ((token, value) in replacements.entries.sortedByDescending { it.key.length }) {
            payload = payload.replace(token, value, ignoreCase = true)
        }
        payload = replacePayloadChoices(payload, "random") { choices ->
            choices[ThreadLocalRandom.current().nextInt(choices.size)]
        }
        payload = replacePayloadChoices(payload, "rotate") { choices ->
            val key = choices.joinToString(";")
            val index = rotationIndexes.computeIfAbsent(key) { AtomicInteger(0) }
                .getAndUpdate { current -> (current + 1) % choices.size }
            choices[index]
        }
        return payload
    }

    private fun replacePayloadChoices(
        input: String,
        kind: String,
        select: (List<String>) -> String,
    ): String {
        val pattern = Regex("\\[$kind=([^\\]]*)\\]", RegexOption.IGNORE_CASE)
        return pattern.replace(input) { match ->
            val choices = match.groupValues[1].split(';').map(String::trim).filter(String::isNotEmpty)
            if (choices.isEmpty()) match.value else select(choices)
        }
    }

    private fun wrapTls(raw: Socket): Socket {
        val sni = config.optString("sni").trim()
        require(sni.isNotEmpty()) { "TLS SNI is required when the TLS wrapper is enabled." }
        val ssl = (SSLSocketFactory.getDefault() as SSLSocketFactory)
            .createSocket(raw, sni, destinationPort, true) as SSLSocket
        ssl.soTimeout = raw.soTimeout
        ssl.startHandshake()
        // Passing the peer hostname above enables SNI through Android's TLS provider.
        // Verify the peer explicitly instead of using SNIHostName/SSLParameters APIs
        // that are unavailable on some supported Android releases.
        require(HttpsURLConnection.getDefaultHostnameVerifier().verify(sni, ssl.session)) {
            "SSH TLS certificate does not match the configured SNI hostname."
        }
        return ssl
    }

    private fun readHttpHeaders(socket: Socket): String {
        val input = socket.getInputStream()
        val bytes = ArrayList<Byte>(256)
        while (bytes.size < 32 * 1024) {
            val byte = input.read()
            if (byte < 0) throw IOException("Proxy closed before returning an HTTP response.")
            bytes.add(byte.toByte())
            val size = bytes.size
            if (size >= 4 && bytes[size - 4] == 13.toByte() && bytes[size - 3] == 10.toByte() &&
                bytes[size - 2] == 13.toByte() && bytes[size - 1] == 10.toByte()) {
                return String(bytes.toByteArray(), StandardCharsets.ISO_8859_1)
            }
        }
        throw IOException("Proxy HTTP response headers exceeded 32 KiB.")
    }

    override fun getInputStream(socket: Socket) = socket.getInputStream()
    override fun getOutputStream(socket: Socket) = socket.getOutputStream()
}
