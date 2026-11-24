package com.swock.vpn.swock.hotspot

import android.util.Log
import java.io.IOException
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Routes Wi-Fi Direct client traffic through the active Android VPN interface using root rules. */
internal class RootHotspotForwarder(
    private val hotspotInterface: String,
    private val vpnInterface: String,
    private val clientSubnet: String,
    private val vpnDns: String,
) {
    private val token = UUID.randomUUID().toString().replace("-", "").take(8).uppercase()
    private val forwardChain = "SWK${token}F"
    private val natChain = "SWK${token}N"
    private val ipv6Chain = "SWK${token}6"
    private val routeTable = 60_000 + (token.take(4).toInt(16) % 5_000)
    private val rulePriority = 500 + (token.takeLast(4).toInt(16) % 3_000)
    private val ready = CountDownLatch(1)
    private val stopped = AtomicBoolean(false)
    private val outputLock = Any()
    private val startupOutput = StringBuilder()
    @Volatile private var readyReceived = false
    @Volatile private var process: Process? = null

    fun start() {
        requireInterfaceName(hotspotInterface)
        requireInterfaceName(vpnInterface)
        require(clientSubnet.matches(Regex("""^(?:\d{1,3}\.){3}\d{1,3}/(?:[1-2]?\d|3[0])$"""))) {
            "The Wi-Fi Direct subnet is invalid."
        }
        require(vpnDns.matches(Regex("""^(?:\d{1,3}\.){3}\d{1,3}$"""))) {
            "The VPN DNS address is invalid."
        }
        require(hotspotInterface != vpnInterface) {
            "The hotspot and VPN interfaces cannot be the same."
        }

        val started = try {
            ProcessBuilder("su", "-c", setupScript()).start()
        } catch (error: IOException) {
            throw IOException("Root access is unavailable: ${error.message}", error)
        }
        process = started
        Thread({
            started.errorStream.bufferedReader().useLines { lines ->
                lines.forEach { line ->
                    synchronized(outputLock) {
                        if (startupOutput.length < MAX_DIAGNOSTIC_LENGTH) {
                            startupOutput.appendLine(line)
                        }
                    }
                }
            }
        }, "swock-hotshare-root-errors").apply {
            isDaemon = true
            start()
        }
        Thread({
            try {
                started.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line ->
                        if (line == READY_MARKER) readyReceived = true
                        else synchronized(outputLock) {
                            if (startupOutput.length < MAX_DIAGNOSTIC_LENGTH) {
                                startupOutput.appendLine(line)
                            }
                        }
                        ready.countDown()
                    }
                }
            } finally {
                ready.countDown()
            }
        }, "swock-hotshare-root-status").apply {
            isDaemon = true
            start()
        }

        val readyInTime = try {
            ready.await(START_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        } catch (error: InterruptedException) {
            Thread.currentThread().interrupt()
            stop()
            throw IOException("Root VPN sharing was interrupted during setup.", error)
        }
        if (!readyInTime || !readyReceived) {
            val detail = synchronized(outputLock) { startupOutput.toString().trim() }
            stop()
            throw IOException(
                detail.ifBlank {
                    "Root routing did not become ready. Grant root access and check that ip, iptables, and ip6tables are available."
                },
            )
        }
        if (!isAlive(started)) {
            val detail = synchronized(outputLock) { startupOutput.toString().trim() }
            process = null
            throw IOException(detail.ifBlank { "Root routing stopped unexpectedly." })
        }
    }

    fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        val current = process ?: return
        process = null
        try {
            current.outputStream.write("$STOP_COMMAND\n".toByteArray(Charsets.US_ASCII))
            current.outputStream.flush()
        } catch (error: IOException) {
            Log.e(TAG, "Could not signal root forwarding cleanup.", error)
        } finally {
            try {
                current.outputStream.close()
            } catch (error: IOException) {
                Log.e(TAG, "Could not close the root forwarding control stream.", error)
            }
        }
        val deadline = System.currentTimeMillis() + STOP_TIMEOUT_MS
        while (isAlive(current) && System.currentTimeMillis() < deadline) {
            try {
                Thread.sleep(50)
            } catch (_: InterruptedException) {
                Thread.currentThread().interrupt()
                break
            }
        }
        if (isAlive(current)) {
            Log.e(TAG, "Root forwarding cleanup timed out; terminating the helper shell.")
            current.destroy()
        }
    }

    private fun setupScript(): String = """
        set -eu
        if [ "$(id -u)" != "0" ]; then
          echo "Root access was denied." >&2
          exit 1
        fi
        for tool in ip iptables ip6tables; do
          command -v "${'$'}tool" >/dev/null 2>&1 || {
            echo "Required root networking tool is missing: ${'$'}tool" >&2
            exit 1
          }
        done
        old_forwarding="${'$'}(cat /proc/sys/net/ipv4/ip_forward)"
        cleanup() {
          while iptables -w -t nat -C PREROUTING -j $natChain 2>/dev/null; do
            iptables -w -t nat -D PREROUTING -j $natChain 2>/dev/null || true
          done
          while iptables -w -t nat -C POSTROUTING -j $natChain 2>/dev/null; do
            iptables -w -t nat -D POSTROUTING -j $natChain 2>/dev/null || true
          done
          while iptables -w -C FORWARD -j $forwardChain 2>/dev/null; do
            iptables -w -D FORWARD -j $forwardChain 2>/dev/null || true
          done
          while ip6tables -w -C FORWARD -j $ipv6Chain 2>/dev/null; do
            ip6tables -w -D FORWARD -j $ipv6Chain 2>/dev/null || true
          done
          iptables -w -t nat -F $natChain 2>/dev/null || true
          iptables -w -t nat -X $natChain 2>/dev/null || true
          iptables -w -F $forwardChain 2>/dev/null || true
          iptables -w -X $forwardChain 2>/dev/null || true
          ip6tables -w -F $ipv6Chain 2>/dev/null || true
          ip6tables -w -X $ipv6Chain 2>/dev/null || true
          ip -4 rule del priority $rulePriority iif $hotspotInterface table $routeTable 2>/dev/null || true
          ip -4 route flush table $routeTable 2>/dev/null || true
          if [ "${'$'}old_forwarding" = "0" ]; then
            printf '0\n' > /proc/sys/net/ipv4/ip_forward 2>/dev/null || true
          fi
        }
        trap cleanup EXIT
        ip -4 route replace default dev $vpnInterface table $routeTable
        ip -4 rule add priority $rulePriority iif $hotspotInterface table $routeTable
        iptables -w -t nat -N $natChain
        iptables -w -t nat -I PREROUTING 1 -j $natChain
        iptables -w -t nat -I POSTROUTING 1 -j $natChain
        iptables -w -t nat -A $natChain -i $hotspotInterface -s $clientSubnet -p udp --dport 53 -j DNAT --to-destination $vpnDns
        iptables -w -t nat -A $natChain -i $hotspotInterface -s $clientSubnet -p tcp --dport 53 -j DNAT --to-destination $vpnDns
        iptables -w -t nat -A $natChain -s $clientSubnet -o $vpnInterface -j MASQUERADE
        iptables -w -N $forwardChain
        iptables -w -I FORWARD 1 -j $forwardChain
        iptables -w -A $forwardChain -i $hotspotInterface -o $vpnInterface -s $clientSubnet -j ACCEPT
        iptables -w -A $forwardChain -i $hotspotInterface -j DROP
        iptables -w -A $forwardChain -i $vpnInterface -o $hotspotInterface -d $clientSubnet -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
        iptables -w -A $forwardChain -o $hotspotInterface -j DROP
        ip6tables -w -N $ipv6Chain
        ip6tables -w -I FORWARD 1 -j $ipv6Chain
        ip6tables -w -A $ipv6Chain -i $hotspotInterface -j DROP
        printf '1\n' > /proc/sys/net/ipv4/ip_forward
        echo $READY_MARKER
        while IFS= read -r command; do
          [ "${'$'}command" = "$STOP_COMMAND" ] && break
        done
    """.trimIndent()

    private fun requireInterfaceName(value: String) {
        require(value.matches(Regex("""^[A-Za-z0-9_.-]{1,15}$"""))) {
            "A network interface name was invalid."
        }
    }

    private fun isAlive(candidate: Process): Boolean = try {
        candidate.exitValue()
        false
    } catch (_: IllegalThreadStateException) {
        true
    }

    companion object {
        private const val READY_MARKER = "SWOCK_HOTSHARE_READY"
        private const val STOP_COMMAND = "STOP"
        private const val START_TIMEOUT_SECONDS = 45L
        private const val STOP_TIMEOUT_MS = 5_000L
        private const val MAX_DIAGNOSTIC_LENGTH = 2_000
        private const val TAG = "RootHotspotForwarder"
    }
}
