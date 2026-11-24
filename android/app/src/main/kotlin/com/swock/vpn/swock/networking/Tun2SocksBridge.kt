package com.swock.vpn.swock.networking

import android.content.Context
import android.os.Build
import android.net.LocalSocket
import android.net.LocalSocketAddress
import android.os.ParcelFileDescriptor
import java.io.File
import java.io.IOException

/** Shared TUN-to-SOCKS bridge used by core and SSH tunnel engines. */
internal class Tun2SocksBridge(
    private val context: Context,
    private val tun: ParcelFileDescriptor,
    private val mtu: Int,
    private val socksPort: Int,
    private val onLog: (String) -> Unit,
    private val enableUdpRelay: Boolean = true,
    private val enableIpv6: Boolean = true,
) {
    private val workingDirectory = context.filesDir
    private val bridgeExecutable = File(context.applicationInfo.nativeLibraryDir, "libv2ray.so")
    private val socketName = "swock_tun2socks.sock"
    private val socketPath = File(workingDirectory, socketName)
    @Volatile private var process: Process? = null

    @Synchronized
    fun start() {
        check(isAlive().not()) { "TUN bridge is already running." }
        if (!workingDirectory.exists() && !workingDirectory.mkdirs()) {
            throw IOException("Could not prepare the TUN bridge directory.")
        }
        if (!bridgeExecutable.isFile || !bridgeExecutable.canExecute()) {
            throw IOException(
                "The bundled TUN helper was not extracted as an executable. Reinstall the APK with native library extraction enabled.",
            )
        }
        socketPath.delete()

        val command = mutableListOf(
            bridgeExecutable.absolutePath,
            "--netif-ipaddr", "26.26.26.2",
            "--netif-netmask", "255.255.255.252",
            "--socks-server-addr", "127.0.0.1:$socksPort",
            "--tunmtu", mtu.coerceIn(576, 9000).toString(),
            "--sock-path", socketName,
            "--loglevel", "error",
        )
        if (enableIpv6) command.addAll(listOf("--netif-ip6addr", "fd26:26:26::2"))
        if (enableUdpRelay) command.add("--enable-udprelay")
        val started = ProcessBuilder(command)
            .directory(workingDirectory)
            .redirectErrorStream(true)
            .start()
        process = started
        Thread({
            runCatching {
                started.inputStream.bufferedReader().useLines { lines ->
                    lines.forEach { line -> if (line.isNotBlank()) onLog("TUN bridge: $line") }
                }
            }
        }, "swock-tun2socks-log").apply { isDaemon = true; start() }

        try {
            sendTunDescriptor(started)
            Thread.sleep(250)
            if (startedHasExited(started)) {
                throw IOException("TUN bridge exited during startup with code ${started.exitValue()}.")
            }
        } catch (error: Exception) {
            stop()
            throw error
        }
        onLog("TUN bridge connected to the local SOCKS endpoint on port $socksPort")
    }

    fun isAlive(): Boolean {
        val running = process ?: return false
        return try {
            running.exitValue()
            false
        } catch (_: IllegalThreadStateException) {
            true
        }
    }

    @Synchronized
    fun stop() {
        val current = process
        process = null
        if (current != null) {
            current.destroy()
            val deadline = System.currentTimeMillis() + 1500
            while (isProcessAlive(current) && System.currentTimeMillis() < deadline) {
                try {
                    Thread.sleep(50)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    break
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && isProcessAlive(current)) current.destroyForcibly()
        }
        socketPath.delete()
    }

    private fun sendTunDescriptor(started: Process) {
        var lastError: IOException? = null
        repeat(40) {
            if (startedHasExited(started)) {
                throw IOException("TUN bridge exited before accepting the VPN interface.")
            }
            val localSocket = LocalSocket()
            try {
                localSocket.connect(
                    LocalSocketAddress(socketPath.absolutePath, LocalSocketAddress.Namespace.FILESYSTEM),
                )
                localSocket.setFileDescriptorsForSend(arrayOf(tun.fileDescriptor))
                localSocket.outputStream.write(32)
                localSocket.setFileDescriptorsForSend(null)
                localSocket.shutdownOutput()
                return
            } catch (error: IOException) {
                lastError = error
                Thread.sleep(100)
            } finally {
                runCatching { localSocket.close() }
            }
        }
        throw IOException("TUN bridge did not accept the VPN interface.", lastError)
    }

    private fun startedHasExited(started: Process): Boolean = try {
        started.exitValue()
        true
    } catch (_: IllegalThreadStateException) {
        false
    }

    private fun isProcessAlive(candidate: Process): Boolean = !startedHasExited(candidate)

}
