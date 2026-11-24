package com.swock.vpn.swock.networking

import com.jcraft.jsch.ChannelDirectTCPIP
import com.jcraft.jsch.Session
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.DataOutputStream
import java.io.EOFException
import java.io.IOException
import java.net.DatagramPacket
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.nio.charset.StandardCharsets
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** Local SOCKS5 endpoint backed by standard SSH direct-tcpip channels. */
internal class SshLocalSocksProxy(
    private val session: Session,
    private val udpGateway: SshUdpGateway?,
    private val onLog: (String) -> Unit,
    private val onFailure: (String) -> Unit,
    private val onUpload: (Int) -> Unit,
    private val onDownload: (Int) -> Unit,
) : Closeable {
    private data class UdpFlowKey(
        val address: String,
        val port: Int,
        val ipv6: Boolean,
    )

    private data class SocksUdpRequest(
        val address: ByteArray,
        val port: Int,
        val ipv6: Boolean,
        val payload: ByteArray,
    )

    private data class UdpResponse(
        val address: ByteArray,
        val port: Int,
        val localPort: Int,
        val ipv6: Boolean,
        val payload: ByteArray,
    )

    private val stopping = AtomicBoolean(false)
    private val unsupportedUdpLogged = AtomicBoolean(false)
    private val nextUdpPort = AtomicInteger(FIRST_UDP_PORT)
    private val activeSockets = ConcurrentHashMap.newKeySet<Socket>()
    private val activeChannels = ConcurrentHashMap.newKeySet<ChannelDirectTCPIP>()
    private val activeUdpAssociations = ConcurrentHashMap.newKeySet<UdpAssociation>()
    private val udpRoutes = ConcurrentHashMap<Int, UdpAssociation>()
    private val dnsTimeouts = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "ssh-dns-timeouts").apply { isDaemon = true }
    }
    @Volatile private var listener: ServerSocket? = null

    val port: Int
        get() = listener?.localPort ?: throw IllegalStateException("SSH SOCKS proxy is not running.")

    fun start() {
        check(listener == null) { "SSH SOCKS proxy is already running." }
        val server = ServerSocket()
        server.reuseAddress = true
        server.bind(InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0), 64)
        listener = server
        Thread({ acceptLoop(server) }, "ssh-socks-accept").apply {
            isDaemon = true
            start()
        }
        onLog("SSH local SOCKS5 proxy listening on 127.0.0.1:${server.localPort}")
    }

    private fun acceptLoop(server: ServerSocket) {
        while (!stopping.get()) {
            try {
                val client = server.accept()
                activeSockets.add(client)
                Thread({ handleClient(client) }, "ssh-socks-client").apply {
                    isDaemon = true
                    start()
                }
            } catch (error: Exception) {
                if (!stopping.get()) {
                    onFailure("SSH local SOCKS proxy stopped: ${error.message ?: "accept failed"}")
                }
                return
            }
        }
    }

    private fun handleClient(client: Socket) {
        var channel: ChannelDirectTCPIP? = null
        var udpAssociation: UdpAssociation? = null
        var replySent = false
        try {
            client.soTimeout = HANDSHAKE_TIMEOUT_MS
            val input = DataInputStream(BufferedInputStream(client.getInputStream()))
            val output = DataOutputStream(BufferedOutputStream(client.getOutputStream()))
            val version = input.readUnsignedByte()
            val methodCount = input.readUnsignedByte()
            val methods = ByteArray(methodCount)
            input.readFully(methods)
            if (version != SOCKS_VERSION || methods.none { (it.toInt() and 0xff) == NO_AUTH }) {
                output.write(byteArrayOf(SOCKS_VERSION.toByte(), NO_ACCEPTABLE_AUTH.toByte()))
                output.flush()
                return
            }
            output.write(byteArrayOf(SOCKS_VERSION.toByte(), NO_AUTH.toByte()))
            output.flush()

            if (input.readUnsignedByte() != SOCKS_VERSION) {
                throw IOException("Unsupported SOCKS version.")
            }
            val command = input.readUnsignedByte()
            input.readUnsignedByte()
            val addressType = input.readUnsignedByte()
            val address = readAddress(input, addressType)
            val destinationPort = input.readUnsignedShort()

            when (command) {
                SOCKS_CONNECT -> {
                    channel = openDirectChannel(address, destinationPort, client)
                    sendReply(output, SOCKS_SUCCESS)
                    replySent = true
                    client.soTimeout = 0
                    relayTcp(client, channel)
                }
                SOCKS_UDP_ASSOCIATE -> {
                    val association = UdpAssociation(client, udpGateway)
                    udpAssociation = association
                    activeUdpAssociations.add(association)
                    association.start()
                    sendReply(output, SOCKS_SUCCESS, association.localPort)
                    replySent = true
                    client.soTimeout = 0
                    while (!stopping.get() && input.read() >= 0) Unit
                    association.close()
                }
                else -> {
                    sendReply(output, SOCKS_COMMAND_UNSUPPORTED)
                    replySent = true
                }
            }
        } catch (error: Exception) {
            if (!replySent) {
                try {
                    DataOutputStream(BufferedOutputStream(client.getOutputStream())).apply {
                        sendReply(this, SOCKS_GENERAL_FAILURE)
                    }
                } catch (_: Exception) {
                    // The client may have disconnected during the SOCKS handshake.
                }
            }
            if (!stopping.get() && error !is EOFException) {
                onLog("SSH SOCKS client closed: ${error.message ?: error.javaClass.simpleName}")
            }
        } finally {
            channel?.let {
                activeChannels.remove(it)
                try {
                    it.disconnect()
                } catch (_: Exception) {
                }
            }
            udpAssociation?.close()
            activeSockets.remove(client)
            try {
                client.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun readAddress(input: DataInputStream, type: Int): String = when (type) {
        ATYP_IPV4 -> InetAddress.getByAddress(ByteArray(4).also(input::readFully)).hostAddress
        ATYP_IPV6 -> InetAddress.getByAddress(ByteArray(16).also(input::readFully)).hostAddress
        ATYP_DOMAIN -> {
            val length = input.readUnsignedByte()
            require(length > 0) { "SOCKS domain name is empty." }
            val bytes = ByteArray(length)
            input.readFully(bytes)
            String(bytes, StandardCharsets.UTF_8)
        }
        else -> throw IOException("SOCKS address type is not supported.")
    }

    private fun openDirectChannel(host: String, port: Int, client: Socket): ChannelDirectTCPIP {
        require(port in 1..65535) { "SOCKS destination port is invalid." }
        val direct = session.openChannel("direct-tcpip") as ChannelDirectTCPIP
        direct.setHost(host)
        direct.setPort(port)
        direct.setOrgIPAddress(client.inetAddress.hostAddress ?: "127.0.0.1")
        direct.setOrgPort(client.port)
        activeChannels.add(direct)
        try {
            direct.connect(DIRECT_CHANNEL_TIMEOUT_MS)
            return direct
        } catch (error: Exception) {
            activeChannels.remove(direct)
            direct.disconnect()
            throw IOException("SSH server could not open $host:$port: ${error.message}", error)
        }
    }

    private fun relayTcp(client: Socket, channel: ChannelDirectTCPIP) {
        val downlink = Thread({
            try {
                copy(channel.inputStream, client.getOutputStream(), onDownload)
            } catch (_: Exception) {
            } finally {
                try {
                    client.close()
                } catch (_: Exception) {
                }
            }
        }, "ssh-socks-downlink").apply {
            isDaemon = true
            start()
        }
        val channelOutput = channel.outputStream
        try {
            copy(client.getInputStream(), channelOutput, onUpload)
        } finally {
            try {
                channelOutput.close()
            } catch (_: Exception) {
            }
            try {
                downlink.join(DOWNLINK_CLOSE_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
            }
        }
    }

    private fun copy(input: java.io.InputStream, output: java.io.OutputStream, onBytes: (Int) -> Unit) {
        val buffer = ByteArray(COPY_BUFFER_SIZE)
        while (!stopping.get()) {
            val count = input.read(buffer)
            if (count < 0) return
            if (count == 0) continue
            output.write(buffer, 0, count)
            output.flush()
            onBytes(count)
        }
    }

    private fun sendReply(output: DataOutputStream, code: Int, port: Int = 0) {
        output.write(byteArrayOf(
            SOCKS_VERSION.toByte(),
            code.toByte(),
            0,
            ATYP_IPV4.toByte(),
            127,
            0,
            0,
            1,
            (port ushr 8).toByte(),
            port.toByte(),
        ))
        output.flush()
    }

    private inner class UdpAssociation(
        private val controlSocket: Socket,
        private val gateway: SshUdpGateway?,
    ) : Closeable {
        private val stopped = AtomicBoolean(false)
        private val flows = ConcurrentHashMap<UdpFlowKey, Int>()
        private val socket = DatagramSocket(
            InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0),
        )
        @Volatile private var clientEndpoint: InetSocketAddress? = null

        val localPort: Int get() = socket.localPort

        fun start() {
            Thread({ readDatagrams() }, "ssh-socks-udp").apply {
                isDaemon = true
                start()
            }
        }

        private fun readDatagrams() {
            val buffer = ByteArray(MAX_UDP_PACKET_SIZE)
            try {
                while (!stopped.get() && !controlSocket.isClosed) {
                    val packet = DatagramPacket(buffer, buffer.size)
                    socket.receive(packet)
                    if (!packet.address.isLoopbackAddress) continue
                    val endpoint = InetSocketAddress(packet.address, packet.port)
                    val first = clientEndpoint
                    if (first == null) clientEndpoint = endpoint
                    else if (first != endpoint) continue
                    val request = parseSocksUdp(packet.data, packet.length) ?: continue
                    if (request.port !in 1..65535) continue
                    val key = UdpFlowKey(
                        InetAddress.getByAddress(request.address).hostAddress.orEmpty(),
                        request.port,
                        request.ipv6,
                    )
                    val sourcePort = flows.computeIfAbsent(key) {
                        reserveUdpPort(this)
                    }
                    val udpGateway = gateway
                    if (udpGateway != null) {
                        val ipPacket = buildUdpPacket(
                            request.address,
                            request.port,
                            request.ipv6,
                            sourcePort,
                            request.payload,
                        )
                        if (!udpGateway.sendPacket(ipPacket) && request.port == DNS_PORT) {
                            tunnelDnsOverTcp(request, sourcePort)
                        }
                    } else if (request.port == DNS_PORT) {
                        tunnelDnsOverTcp(request, sourcePort)
                    } else if (unsupportedUdpLogged.compareAndSet(false, true)) {
                        onLog("SSH UDP requires the optional SSH UDP Gateway; DNS is being forwarded over TCP")
                    }
                }
            } catch (error: Exception) {
                if (!stopped.get() && !controlSocket.isClosed) {
                    onLog("SSH UDP relay stopped: ${error.message ?: error.javaClass.simpleName}")
                }
            }
        }

        private fun tunnelDnsOverTcp(request: SocksUdpRequest, localPort: Int) {
            Thread({
                var channel: ChannelDirectTCPIP? = null
                var timeout: ScheduledFuture<*>? = null
                try {
                    val dnsHost = InetAddress.getByAddress(request.address).hostAddress
                        ?: throw IOException("Could not determine DNS server address.")
                    val dnsChannel = openDirectChannel(dnsHost, request.port, controlSocket)
                    channel = dnsChannel
                    timeout = dnsTimeouts.schedule(
                        { dnsChannel.disconnect() },
                        DNS_TIMEOUT_MS.toLong(),
                        TimeUnit.MILLISECONDS,
                    )
                    val output = DataOutputStream(BufferedOutputStream(dnsChannel.outputStream))
                    output.writeShort(request.payload.size)
                    output.write(request.payload)
                    output.flush()
                    onUpload(request.payload.size)

                    val input = DataInputStream(BufferedInputStream(dnsChannel.inputStream))
                    val responseLength = input.readUnsignedShort()
                    require(responseLength >= MIN_DNS_MESSAGE_SIZE) {
                        "DNS-over-TCP response was too short."
                    }
                    val response = ByteArray(responseLength)
                    input.readFully(response)
                    onDownload(response.size)
                    sendResponse(
                        UdpResponse(
                            address = request.address,
                            port = request.port,
                            localPort = localPort,
                            ipv6 = request.ipv6,
                            payload = response,
                        ),
                    )
                } catch (error: Exception) {
                    if (!stopped.get() && !controlSocket.isClosed) {
                        onLog("SSH DNS-over-TCP request failed: ${error.message ?: error.javaClass.simpleName}")
                    }
                } finally {
                    timeout?.cancel(false)
                    channel?.let {
                        activeChannels.remove(it)
                        try {
                            it.disconnect()
                        } catch (_: Exception) {
                        }
                    }
                }
            }, "ssh-socks-dns").apply {
                isDaemon = true
                start()
            }
        }

        fun sendResponse(response: UdpResponse) {
            if (stopped.get()) return
            val destination = clientEndpoint ?: return
            val encoded = encodeSocksUdp(response)
            val packet = DatagramPacket(encoded, encoded.size, destination.address, destination.port)
            try {
                socket.send(packet)
            } catch (error: Exception) {
                if (!stopped.get()) onLog("Could not return SSH UDP response: ${error.message}")
            }
        }

        override fun close() {
            if (!stopped.compareAndSet(false, true)) return
            socket.close()
            flows.values.forEach { udpRoutes.remove(it, this) }
            activeUdpAssociations.remove(this)
        }
    }

    private fun reserveUdpPort(association: UdpAssociation): Int {
        repeat(20_000) {
            val port = nextUdpPort.getAndUpdate { current ->
                if (current >= LAST_UDP_PORT) FIRST_UDP_PORT else current + 1
            }
            if (udpRoutes.putIfAbsent(port, association) == null) return port
        }
        throw IOException("SSH UDP relay has too many active flows.")
    }

    fun routeUdpResponse(packet: ByteArray) {
        val response = parseUdpResponse(packet) ?: return
        udpRoutes[response.localPort]?.sendResponse(response)
    }

    private fun parseSocksUdp(packet: ByteArray, length: Int): SocksUdpRequest? {
        if (length < 10 || packet[0] != 0.toByte() || packet[1] != 0.toByte() ||
            packet[2] != 0.toByte()
        ) return null
        var offset = 4
        val type = packet[3].toInt() and 0xff
        val ipv6: Boolean
        val addressSize: Int
        when (type) {
            ATYP_IPV4 -> {
                ipv6 = false
                addressSize = 4
            }
            ATYP_IPV6 -> {
                ipv6 = true
                addressSize = 16
            }
            ATYP_DOMAIN -> return null
            else -> return null
        }
        if (length < offset + addressSize + 2) return null
        val address = packet.copyOfRange(offset, offset + addressSize)
        offset += addressSize
        val port = unsignedShort(packet, offset)
        offset += 2
        val payload = packet.copyOfRange(offset, length)
        if (payload.isEmpty()) return null
        return SocksUdpRequest(address, port, ipv6, payload)
    }

    private fun buildUdpPacket(
        destination: ByteArray,
        destinationPort: Int,
        ipv6: Boolean,
        sourcePort: Int,
        payload: ByteArray,
    ): ByteArray {
        return if (ipv6) {
            buildIpv6UdpPacket(destination, destinationPort, sourcePort, payload)
        } else {
            buildIpv4UdpPacket(destination, destinationPort, sourcePort, payload)
        }
    }

    private fun buildIpv4UdpPacket(
        destination: ByteArray,
        destinationPort: Int,
        sourcePort: Int,
        payload: ByteArray,
    ): ByteArray {
        val packet = ByteArray(28 + payload.size)
        packet[0] = 0x45
        putShort(packet, 2, packet.size)
        packet[8] = 64
        packet[9] = IPPROTO_UDP.toByte()
        val source = IPV4_TUN_PEER.address
        source.copyInto(packet, 12)
        destination.copyInto(packet, 16)
        putShort(packet, 20, sourcePort)
        putShort(packet, 22, destinationPort)
        putShort(packet, 24, payload.size + 8)
        payload.copyInto(packet, 28)
        putShort(packet, 10, checksum(packet, 0, 20))
        return packet
    }

    private fun buildIpv6UdpPacket(
        destination: ByteArray,
        destinationPort: Int,
        sourcePort: Int,
        payload: ByteArray,
    ): ByteArray {
        val udpLength = payload.size + 8
        val packet = ByteArray(40 + udpLength)
        packet[0] = 0x60
        putShort(packet, 4, udpLength)
        packet[6] = IPPROTO_UDP.toByte()
        packet[7] = 64
        IPV6_TUN_PEER.address.copyInto(packet, 8)
        destination.copyInto(packet, 24)
        putShort(packet, 40, sourcePort)
        putShort(packet, 42, destinationPort)
        putShort(packet, 44, udpLength)
        payload.copyInto(packet, 48)
        putShort(packet, 46, ipv6UdpChecksum(packet, udpLength))
        return packet
    }

    private fun parseUdpResponse(packet: ByteArray): UdpResponse? {
        if (packet.size < 28) return null
        val version = (packet[0].toInt() ushr 4) and 0xf
        val ipv6: Boolean
        val udpOffset: Int
        val addressOffset: Int
        val sourceSize: Int
        when (version) {
            4 -> {
                val headerLength = (packet[0].toInt() and 0xf) * 4
                val totalLength = unsignedShort(packet, 2)
                if (headerLength < 20 || totalLength < headerLength + 8 ||
                    totalLength > packet.size ||
                    (packet[9].toInt() and 0xff) != IPPROTO_UDP
                ) return null
                ipv6 = false
                udpOffset = headerLength
                addressOffset = 12
                sourceSize = 4
            }
            6 -> {
                val totalLength = 40 + unsignedShort(packet, 4)
                if (packet.size < 48 || totalLength < 48 || totalLength > packet.size ||
                    (packet[6].toInt() and 0xff) != IPPROTO_UDP
                ) return null
                ipv6 = true
                udpOffset = 40
                addressOffset = 8
                sourceSize = 16
            }
            else -> return null
        }
        if (packet.size < udpOffset + 8) return null
        val udpLength = unsignedShort(packet, udpOffset + 4)
        val packetLength = if (ipv6) 40 + unsignedShort(packet, 4) else unsignedShort(packet, 2)
        if (udpLength < 8 || packetLength < udpOffset + udpLength) return null
        return UdpResponse(
            address = packet.copyOfRange(addressOffset, addressOffset + sourceSize),
            port = unsignedShort(packet, udpOffset),
            localPort = unsignedShort(packet, udpOffset + 2),
            ipv6 = ipv6,
            payload = packet.copyOfRange(udpOffset + 8, udpOffset + udpLength),
        )
    }

    private fun encodeSocksUdp(response: UdpResponse): ByteArray {
        val header = if (response.ipv6) 22 else 10
        return ByteArray(header + response.payload.size).also { packet ->
            packet[0] = 0
            packet[1] = 0
            packet[2] = 0
            packet[3] = (if (response.ipv6) ATYP_IPV6 else ATYP_IPV4).toByte()
            response.address.copyInto(packet, 4)
            val offset = 4 + response.address.size
            putShort(packet, offset, response.port)
            response.payload.copyInto(packet, offset + 2)
        }
    }

    private fun ipv6UdpChecksum(packet: ByteArray, udpLength: Int): Int {
        var sum = addWords(0, packet, 8, 32)
        sum += (udpLength ushr 16).toLong() + (udpLength and 0xffff).toLong()
        sum += IPPROTO_UDP.toLong()
        sum = addWords(sum, packet, 40, udpLength)
        while (sum ushr 16 != 0L) sum = (sum and 0xffff) + (sum ushr 16)
        return (sum.inv() and 0xffff).toInt().let { if (it == 0) 0xffff else it }
    }

    private fun checksum(bytes: ByteArray, start: Int, length: Int): Int {
        var sum = addWords(0, bytes, start, length)
        while (sum ushr 16 != 0L) sum = (sum and 0xffff) + (sum ushr 16)
        return (sum.inv() and 0xffff).toInt()
    }

    private fun addWords(initial: Long, bytes: ByteArray, start: Int, length: Int): Long {
        var sum = initial
        var index = start
        val end = start + length
        while (index + 1 < end) {
            sum += (((bytes[index].toInt() and 0xff) shl 8) or
                (bytes[index + 1].toInt() and 0xff)).toLong()
            index += 2
        }
        if (index < end) sum += ((bytes[index].toInt() and 0xff) shl 8).toLong()
        return sum
    }

    private fun unsignedShort(bytes: ByteArray, index: Int): Int =
        ((bytes[index].toInt() and 0xff) shl 8) or (bytes[index + 1].toInt() and 0xff)

    private fun putShort(bytes: ByteArray, index: Int, value: Int) {
        bytes[index] = (value ushr 8).toByte()
        bytes[index + 1] = value.toByte()
    }

    override fun close() {
        if (!stopping.compareAndSet(false, true)) return
        dnsTimeouts.shutdownNow()
        try {
            listener?.close()
        } catch (_: Exception) {
        }
        listener = null
        activeSockets.toList().forEach { socket ->
            try {
                socket.close()
            } catch (_: Exception) {
            }
        }
        activeChannels.toList().forEach { channel ->
            try {
                channel.disconnect()
            } catch (_: Exception) {
            }
        }
        activeUdpAssociations.toList().forEach { it.close() }
        onLog("SSH local SOCKS5 proxy stopped")
    }

    companion object {
        private const val SOCKS_VERSION = 5
        private const val NO_AUTH = 0
        private const val NO_ACCEPTABLE_AUTH = 0xff
        private const val SOCKS_CONNECT = 1
        private const val SOCKS_UDP_ASSOCIATE = 3
        private const val SOCKS_SUCCESS = 0
        private const val SOCKS_GENERAL_FAILURE = 1
        private const val SOCKS_COMMAND_UNSUPPORTED = 7
        private const val ATYP_IPV4 = 1
        private const val ATYP_DOMAIN = 3
        private const val ATYP_IPV6 = 4
        private const val DIRECT_CHANNEL_TIMEOUT_MS = 15_000
        private const val HANDSHAKE_TIMEOUT_MS = 15_000
        private const val DOWNLINK_CLOSE_TIMEOUT_MS = 2_000L
        private const val COPY_BUFFER_SIZE = 32 * 1024
        private const val MAX_UDP_PACKET_SIZE = 65_535
        private const val FIRST_UDP_PORT = 40_000
        private const val LAST_UDP_PORT = 60_000
        private const val IPPROTO_UDP = 17
        private const val DNS_PORT = 53
        private const val MIN_DNS_MESSAGE_SIZE = 12
        private const val DNS_TIMEOUT_MS = 5_000
        private val IPV4_TUN_PEER = InetAddress.getByName("26.26.26.1")
        private val IPV6_TUN_PEER = InetAddress.getByName("fd26:26:26::1")

        private fun unsignedShort(bytes: ByteArray, index: Int): Int =
            ((bytes[index].toInt() and 0xff) shl 8) or (bytes[index + 1].toInt() and 0xff)

        private fun putShort(bytes: ByteArray, index: Int, value: Int) {
            bytes[index] = (value ushr 8).toByte()
            bytes[index + 1] = value.toByte()
        }
    }
}
