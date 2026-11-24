package com.swock.vpn.swock.networking

import java.io.Closeable
import java.io.DataInputStream
import java.io.EOFException
import java.io.InputStream
import java.io.OutputStream
import java.net.InetAddress
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger

/** BadVPN UDPGW client carried inside an authenticated SSH direct-tcpip channel. */
internal class SshUdpGateway(
    input: InputStream,
    private val output: OutputStream,
    private val onTunPacket: (ByteArray) -> Unit,
    private val onFailure: (String) -> Unit,
    private val onUpload: (Int) -> Unit,
    private val onDownload: (Int) -> Unit,
) : Closeable {
    private data class FlowKey(
        val sourceAddress: String,
        val sourcePort: Int,
        val destinationAddress: String,
        val destinationPort: Int,
        val ipv6: Boolean,
    )

    private data class Flow(
        val key: FlowKey,
        val sourceAddress: ByteArray,
        val sourcePort: Int,
        val destinationAddress: ByteArray,
        val destinationPort: Int,
        val ipv6: Boolean,
        var needsRebind: Boolean = true,
        var connectionId: Int = -1,
    )

    private data class UdpPacket(val flow: Flow, val payload: ByteArray)

    private val stopped = AtomicBoolean(false)
    private val input = DataInputStream(input.buffered())
    private val writerLock = Any()
    private val flowLock = Any()
    private val nextId = AtomicInteger(0)
    private val flowsByKey = HashMap<FlowKey, Flow>()
    private val flowsById = ConcurrentHashMap<Int, Flow>()

    init {
        Thread(::readLoop, "swock-ssh-udpgw-down").start()
        Thread(::keepaliveLoop, "swock-ssh-udpgw-ping").start()
    }

    /** Returns true only when a complete UDP packet was sent through UDPGW. */
    fun sendPacket(packet: ByteArray): Boolean {
        val parsed = parseUdpPacket(packet) ?: return false
        val addressSize = if (parsed.flow.ipv6) 18 else 6
        if (3 + addressSize + parsed.payload.size > MAX_FRAME_SIZE) return false
        val flow = getOrCreateFlow(parsed.flow)
        val body = ByteArray(3 + addressSize + parsed.payload.size)
        var offset = 0
        body[offset++] = ((if (flow.ipv6) FLAG_IPV6 else 0) or
            (if (flow.needsRebind) FLAG_REBIND else 0)).toByte()
        body[offset++] = flow.connectionId.toByte()
        body[offset++] = (flow.connectionId ushr 8).toByte()
        flow.destinationAddress.copyInto(body, offset)
        offset += flow.destinationAddress.size
        body[offset++] = flow.destinationPort.toByte()
        body[offset++] = (flow.destinationPort ushr 8).toByte()
        parsed.payload.copyInto(body, offset)
        synchronized(writerLock) {
            check(!stopped.get()) { "SSH UDP gateway is closed." }
            writeFrame(body)
            flow.needsRebind = false
        }
        onUpload(packet.size)
        return true
    }

    private fun getOrCreateFlow(candidate: Flow): Flow = synchronized(flowLock) {
        flowsByKey[candidate.key]?.let { return it }
        val id = nextId.getAndUpdate { (it + 1) and 0xffff }
        flowsById.remove(id)?.let { flowsByKey.remove(it.key) }
        candidate.connectionId = id
        flowsByKey[candidate.key] = candidate
        flowsById[id] = candidate
        candidate
    }

    private fun readLoop() {
        try {
            while (!stopped.get()) {
                val lengthLow = input.read()
                if (lengthLow < 0) throw EOFException("UDPGW connection closed.")
                val lengthHigh = input.read()
                if (lengthHigh < 0) throw EOFException("UDPGW frame ended unexpectedly.")
                val length = lengthLow or (lengthHigh shl 8)
                require(length in 3..MAX_FRAME_SIZE) { "UDPGW sent an invalid frame." }
                val body = ByteArray(length)
                input.readFully(body)
                receiveFrame(body)
            }
        } catch (error: Exception) {
            if (!stopped.get()) {
                onFailure(error.message?.takeIf { it.isNotBlank() } ?: "UDPGW connection failed.")
            }
        }
    }

    private fun receiveFrame(body: ByteArray) {
        val flags = body[0].toInt() and 0xff
        if (flags and FLAG_KEEPALIVE != 0) return
        val id = (body[1].toInt() and 0xff) or ((body[2].toInt() and 0xff) shl 8)
        val flow = flowsById[id] ?: return
        val addressSize = if (flags and FLAG_IPV6 != 0) 16 else 4
        require(body.size >= 3 + addressSize + 2) { "UDPGW response omitted its address." }
        val remoteAddress = body.copyOfRange(3, 3 + addressSize)
        val remotePortOffset = 3 + addressSize
        val remotePort = (body[remotePortOffset].toInt() and 0xff) or
            ((body[remotePortOffset + 1].toInt() and 0xff) shl 8)
        if (!remoteAddress.contentEquals(flow.destinationAddress) ||
            remotePort != flow.destinationPort
        ) return
        val payload = body.copyOfRange(remotePortOffset + 2, body.size)
        val packet = buildReply(flow, payload)
        onTunPacket(packet)
        onDownload(packet.size)
    }

    private fun writeFrame(body: ByteArray) {
        output.write(body.size and 0xff)
        output.write((body.size ushr 8) and 0xff)
        output.write(body)
        output.flush()
    }

    private fun keepaliveLoop() {
        try {
            while (!stopped.get()) {
                Thread.sleep(20_000)
                if (stopped.get()) return
                synchronized(writerLock) {
                    if (!stopped.get()) {
                        writeFrame(byteArrayOf(FLAG_KEEPALIVE.toByte(), 0, 0))
                    }
                }
            }
        } catch (error: Exception) {
            if (!stopped.get()) {
                onFailure(error.message?.takeIf { it.isNotBlank() } ?: "UDPGW keepalive failed.")
            }
        }
    }

    override fun close() {
        if (!stopped.compareAndSet(false, true)) return
        try { input.close() } catch (_: Exception) {}
        try { output.close() } catch (_: Exception) {}
        synchronized(flowLock) {
            flowsByKey.clear()
            flowsById.clear()
        }
    }

    private fun parseUdpPacket(packet: ByteArray): UdpPacket? {
        if (packet.isEmpty()) return null
        return when ((packet[0].toInt() ushr 4) and 0xf) {
            4 -> parseIpv4Udp(packet)
            6 -> parseIpv6Udp(packet)
            else -> null
        }
    }

    private fun parseIpv4Udp(packet: ByteArray): UdpPacket? {
        if (packet.size < 28 || (packet[9].toInt() and 0xff) != IPPROTO_UDP) return null
        val headerSize = (packet[0].toInt() and 0xf) * 4
        val totalSize = unsignedShort(packet, 2)
        val fragments = unsignedShort(packet, 6)
        if (headerSize < 20 || totalSize > packet.size || totalSize < headerSize + 8 ||
            (fragments and 0x3fff) != 0
        ) return null
        val udpOffset = headerSize
        val udpLength = unsignedShort(packet, udpOffset + 4)
        if (udpLength < 8 || udpOffset + udpLength > totalSize) return null
        val source = packet.copyOfRange(12, 16)
        val destination = packet.copyOfRange(16, 20)
        val flow = makeFlow(
            source, unsignedShort(packet, udpOffset),
            destination, unsignedShort(packet, udpOffset + 2), false,
        )
        return UdpPacket(flow, packet.copyOfRange(udpOffset + 8, udpOffset + udpLength))
    }

    private fun parseIpv6Udp(packet: ByteArray): UdpPacket? {
        if (packet.size < 48) return null
        val payloadLength = unsignedShort(packet, 4)
        val totalSize = 40 + payloadLength
        if (totalSize > packet.size) return null
        var nextHeader = packet[6].toInt() and 0xff
        var udpOffset = 40
        var extensions = 0
        while (nextHeader != IPPROTO_UDP) {
            if (++extensions > 8 || udpOffset + 2 > totalSize) return null
            val current = nextHeader
            nextHeader = packet[udpOffset].toInt() and 0xff
            val extensionLength = when (current) {
                0, 43, 60, 135 -> ((packet[udpOffset + 1].toInt() and 0xff) + 1) * 8
                44 -> {
                    if (udpOffset + 8 > totalSize) return null
                    val fragment = unsignedShort(packet, udpOffset + 2)
                    if ((fragment and 0xfff9) != 0) return null
                    8
                }
                51 -> ((packet[udpOffset + 1].toInt() and 0xff) + 2) * 4
                else -> return null
            }
            if (extensionLength <= 0 || udpOffset + extensionLength > totalSize) return null
            udpOffset += extensionLength
        }
        if (udpOffset + 8 > totalSize) return null
        val udpLength = unsignedShort(packet, udpOffset + 4)
        if (udpLength < 8 || udpOffset + udpLength > totalSize) return null
        val source = packet.copyOfRange(8, 24)
        val destination = packet.copyOfRange(24, 40)
        val flow = makeFlow(
            source, unsignedShort(packet, udpOffset),
            destination, unsignedShort(packet, udpOffset + 2), true,
        )
        return UdpPacket(flow, packet.copyOfRange(udpOffset + 8, udpOffset + udpLength))
    }

    private fun makeFlow(
        source: ByteArray,
        sourcePort: Int,
        destination: ByteArray,
        destinationPort: Int,
        ipv6: Boolean,
    ): Flow {
        val sourceText = InetAddress.getByAddress(source).hostAddress.orEmpty()
        val destinationText = InetAddress.getByAddress(destination).hostAddress.orEmpty()
        val key = FlowKey(sourceText, sourcePort, destinationText, destinationPort, ipv6)
        return Flow(key, source, sourcePort, destination, destinationPort, ipv6)
    }

    private fun buildReply(flow: Flow, payload: ByteArray): ByteArray =
        if (flow.ipv6) buildIpv6Reply(flow, payload) else buildIpv4Reply(flow, payload)

    private fun buildIpv4Reply(flow: Flow, payload: ByteArray): ByteArray {
        val total = 28 + payload.size
        require(total <= 65535) { "UDPGW returned an oversized IPv4 packet." }
        val packet = ByteArray(total)
        packet[0] = 0x45
        putShort(packet, 2, total)
        putShort(packet, 4, nextPacketId.getAndUpdate { (it + 1) and 0xffff })
        packet[8] = 64
        packet[9] = IPPROTO_UDP.toByte()
        flow.destinationAddress.copyInto(packet, 12)
        flow.sourceAddress.copyInto(packet, 16)
        putShort(packet, 20, flow.destinationPort)
        putShort(packet, 22, flow.sourcePort)
        putShort(packet, 24, payload.size + 8)
        payload.copyInto(packet, 28)
        putShort(packet, 10, checksum(packet, 0, 20))
        return packet
    }

    private fun buildIpv6Reply(flow: Flow, payload: ByteArray): ByteArray {
        val udpLength = payload.size + 8
        require(udpLength <= 65535) { "UDPGW returned an oversized IPv6 packet." }
        val packet = ByteArray(40 + udpLength)
        packet[0] = 0x60
        putShort(packet, 4, udpLength)
        packet[6] = IPPROTO_UDP.toByte()
        packet[7] = 64
        flow.destinationAddress.copyInto(packet, 8)
        flow.sourceAddress.copyInto(packet, 24)
        putShort(packet, 40, flow.destinationPort)
        putShort(packet, 42, flow.sourcePort)
        putShort(packet, 44, udpLength)
        payload.copyInto(packet, 48)
        putShort(packet, 46, ipv6UdpChecksum(packet, udpLength))
        return packet
    }

    private fun ipv6UdpChecksum(packet: ByteArray, udpLength: Int): Int {
        var sum = 0L
        sum = addWords(sum, packet, 8, 32)
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
            sum += ((bytes[index].toInt() and 0xff) shl 8 or
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

    companion object {
        private const val FLAG_KEEPALIVE = 1
        private const val FLAG_REBIND = 2
        private const val FLAG_IPV6 = 8
        private const val IPPROTO_UDP = 17
        private const val MAX_FRAME_SIZE = 65535
        private val nextPacketId = AtomicInteger(1)
    }
}
