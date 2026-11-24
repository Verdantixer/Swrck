package com.swock.vpn.swock

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.content.Intent
import android.content.Context
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Build
import android.net.VpnService
import android.net.wifi.WifiManager
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import com.swock.vpn.swock.networking.AdvancedOptions
import com.swock.vpn.swock.networking.ProfileVpnEngine
import com.swock.vpn.swock.networking.SingboxCoreEngine
import com.swock.vpn.swock.networking.SshVpnEngine
import com.swock.vpn.swock.networking.XrayCoreEngine
import com.swock.vpn.swock.networking.XrayProfileConfigurationException
import com.swock.vpn.swock.networking.XrayRuntimeException
import org.json.JSONObject
import java.net.Inet4Address
import java.net.Inet6Address

class MyVpnService : VpnService() {
    @Volatile private var shouldRun = false
    @Volatile private var vpnInterface: ParcelFileDescriptor? = null
    @Volatile private var worker: Thread? = null
    private var wifiLock: WifiManager.WifiLock? = null
    private var cpuLock: PowerManager.WakeLock? = null
    private val retryMonitor = Object()
    private val connectivityManager by lazy { getSystemService(ConnectivityManager::class.java) }
    @Volatile private var underlyingNetwork: Network? = null
    private val engine by lazy {
        ProfileVpnEngine(
            this,
            underlyingNetwork = { underlyingNetwork },
            onStatus = { state, message ->
                currentStatus = mapOf("state" to state, "connected" to (state == "connected"), "message" to message)
                recordVpnEvent(message)
                if (shouldRun) updateVpnNotification(state)
            },
            onLog = { recordVpnEvent(it) },
        )
    }
    private val networkCallback = object : ConnectivityManager.NetworkCallback() {
        override fun onAvailable(network: Network) {
            val capabilities = connectivityManager.getNetworkCapabilities(network)
            if (capabilities?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) != true) {
                val oldNetwork = underlyingNetwork
                underlyingNetwork = network
                if (shouldRun && oldNetwork != null && oldNetwork != network) {
                    recordVpnEvent("Network switched to ${networkType(network)}; reconnecting tunnel")
                    engine.forceReconnect("Network switched; reconnecting")
                }
            }
            synchronized(retryMonitor) { retryMonitor.notifyAll() }
        }

        override fun onLost(network: Network) {
            if (underlyingNetwork == network) {
                underlyingNetwork = getUnderlyingNetwork()
                if (shouldRun) {
                    recordVpnEvent("Active transport network lost; reconnecting tunnel")
                    engine.forceReconnect("Transport network changed; reconnecting")
                }
            }
            synchronized(retryMonitor) { retryMonitor.notifyAll() }
        }
    }

    companion object {
        const val EXTRA_PROFILE = "profile"
        const val EXTRA_STOP = "stop"
        private const val PREFS = "swock_vpn_service"
        private const val PROFILE_KEY = "desired_profile"
        @Volatile private var currentStatus: Map<String, Any?> = mapOf("state" to "disconnected", "connected" to false, "message" to "Disconnected")
        @Volatile private var currentStatistics: Map<String, Any?> = mapOf("downloadBytes" to 0L, "uploadBytes" to 0L, "durationMs" to 0L)
        private val vpnEvents = ArrayDeque<Map<String, Any?>>()

        fun recordVpnEvent(message: String) {
            synchronized(vpnEvents) {
                vpnEvents.addLast(mapOf("timestamp" to System.currentTimeMillis(), "message" to message))
                while (vpnEvents.size > 500) vpnEvents.removeFirst()
            }
        }

        fun updateStatus(state: String, message: String) {
            currentStatus = mapOf(
                "state" to state,
                "connected" to (state == "connected"),
                "message" to message,
            )
            recordVpnEvent(message)
        }

        fun drainVpnEvents(): List<Map<String, Any?>> = synchronized(vpnEvents) {
            buildList {
                while (vpnEvents.isNotEmpty()) add(vpnEvents.removeFirst())
            }
        }

        fun clearVpnEvents() = synchronized(vpnEvents) { vpnEvents.clear() }

        fun status(): Map<String, Any?> = currentStatus
        fun statistics(): Map<String, Any?> = currentStatistics
        fun validateProfile(profileJson: String): String? = try {
            val profile = JSONObject(profileJson)
            val protocol = profile.optString("protocol", "xray").lowercase()
            val singboxCore = profile.optString("core").equals("singbox", ignoreCase = true)
            if (protocol == "ssh") {
                SshVpnEngine.validateConfig(profileJson)
            } else if (singboxCore) {
                SingboxCoreEngine.validateProfile(profileJson)
            } else XrayCoreEngine.validateProfile(profileJson)
        } catch (_: Exception) {
            "Profile data could not be read"
        }

        fun testConnection(profileJson: String): Boolean = validateProfile(profileJson) == null
    }

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        underlyingNetwork = getUnderlyingNetwork()
        try {
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN)
                .build()
            connectivityManager.registerNetworkCallback(request, networkCallback)
        } catch (_: Exception) { }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.getBooleanExtra(EXTRA_STOP, false) == true) {
            stopRequestedByUser()
            return START_NOT_STICKY
        }
        val stored = getSharedPreferences(PREFS, MODE_PRIVATE)
        val profileJson = intent?.getStringExtra(EXTRA_PROFILE) ?: stored.getString(PROFILE_KEY, null)
        if (profileJson.isNullOrBlank()) {
            currentStatus = mapOf("state" to "disconnected", "connected" to false, "message" to "Disconnected")
            stopSelf()
            return START_NOT_STICKY
        }
        validateProfile(profileJson)?.let { error ->
            currentStatus = mapOf("state" to "error", "connected" to false, "message" to error)
            recordVpnEvent(error)
            stopSelf()
            return START_NOT_STICKY
        }
        stored.edit().putString(PROFILE_KEY, profileJson).apply()
        shouldRun = true
        recordVpnEvent("VPN service started")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(1, buildNotification("connecting"), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(1, buildNotification("connecting"))
        }
        if (worker?.isAlive != true) {
            worker = Thread({ runConnectionLoop(profileJson) }, "swock-vpn-reconnect").also { it.start() }
        } else if (intent?.hasExtra(EXTRA_PROFILE) == true) {
            engine.forceReconnect("Profile changed; reconnecting")
        }
        return START_STICKY
    }

    private fun runConnectionLoop(profileJson: String) {
        var retries = 0
        while (shouldRun) {
            try {
                currentStatus = mapOf(
                    "state" to if (retries == 0) "connecting" else "reconnecting",
                    "connected" to false,
                    "message" to if (retries == 0) "Preparing VPN interface" else "Retry attempt $retries",
                    "attempt" to retries,
                )
                updateVpnNotification(currentStatus["state"].toString())
                recordVpnEvent(currentStatus["message"].toString())
                closeVpnInterface()
                val profile = JSONObject(profileJson)
                val sshTunnel = profile.optString("protocol").equals("ssh", true)
                val singboxCore = profile.optString("core").equals("singbox", ignoreCase = true)
                val protocolLabel = when (profile.optString("protocol").lowercase()) {
                    "ssh" -> "SSH"
                    "hysteria2" -> "Hysteria 2"
                    "directproxy" -> "Direct proxy"
                    "xray" -> if (singboxCore) "Sing-box JSON" else "Xray JSON"
                    else -> profile.optString("protocol").uppercase().ifBlank { "Proxy" }
                }
                val builder = Builder().setSession(when {
                    sshTunnel -> "Swock · SSH"
                    else -> "Swock · $protocolLabel"
                })
                val mtu = when {
                    sshTunnel -> profile.optJSONObject("ssh")?.optInt("mtu", 1400) ?: 1400
                    singboxCore -> SingboxCoreEngine.configuredMtu(profileJson)
                    else -> XrayCoreEngine.configuredMtu(profileJson)
                }
                val advanced = AdvancedOptions.from(profile)
                val engineProfileJson: String
                if (sshTunnel) {
                    builder.addAddress("26.26.26.1", 30)
                        .addRoute("0.0.0.0", 0)
                        .addAddress("fd26:26:26::1", 126)
                        .addRoute("::", 0)
                    engineProfileJson = profile.toString()
                } else {
                    builder.addAddress("26.26.26.1", 30)
                        .addRoute("0.0.0.0", 0)
                        .addAddress("fd26:26:26::1", 126)
                        .addRoute("::", 0)
                    engineProfileJson = profileJson
                }
                builder.setMtu(mtu)
                val ipStack = if (advanced.ipv6Enabled) "dual-stack" else "IPv4-only; IPv6 blocked"
                recordVpnEvent(when {
                    sshTunnel -> "Starting SSH tunnel ($ipStack, MTU $mtu)"
                    singboxCore -> "Starting $protocolLabel via Sing-box with $ipStack routes (MTU $mtu)"
                    else -> "Starting $protocolLabel via Xray-core with $ipStack routes (MTU $mtu)"
                })
                val physicalNetwork = getUnderlyingNetwork()
                val netLabel = physicalNetwork?.let { networkType(it) } ?: "system default network"
                val engineLabel = when {
                    sshTunnel -> "SSH"
                    singboxCore -> "$protocolLabel via Sing-box"
                    else -> "$protocolLabel via Xray-core"
                }
                recordVpnEvent("Attempt ${retries + 1}: $engineLabel over $netLabel")
                if (physicalNetwork != null) {
                    builder.setUnderlyingNetworks(arrayOf(physicalNetwork))
                } else {
                    builder.setUnderlyingNetworks(null)
                }
                if (advanced.summary().isNotEmpty()) recordVpnEvent("Advanced options: ${advanced.summary()}")
                if (advanced.callStability) acquireStabilityLocks() else releaseStabilityLocks()
                val dns = profile.optJSONObject("dns")
                val dnsEnabled = dns?.optBoolean("enabled", false) == true
                val customDnsServers = if (dnsEnabled) {
                    listOf("primary", "secondary", "tertiary")
                        .mapNotNull { dns?.optString(it)?.trim() }
                        .filter {
                            it.isNotEmpty() && isValidIpAddress(it) &&
                                (advanced.ipv6Enabled || ':' !in it)
                        }
                } else emptyList()
                // Use the active network's resolvers unless the profile provides DNS;
                // do not inject public resolver addresses when the network has none.
                val physicalDnsServers = try {
                    physicalNetwork?.let { connectivityManager.getLinkProperties(it)?.dnsServers }
                        .orEmpty()
                        .filter { it is Inet4Address || it is Inet6Address }
                        .mapNotNull { it.hostAddress?.substringBefore('%') }
                        .filter {
                            it.isNotEmpty() && isValidIpAddress(it) &&
                                (advanced.ipv6Enabled || ':' !in it)
                        }
                } catch (_: Exception) { emptyList() }
                val dnsServers =
                    (customDnsServers.ifEmpty { physicalDnsServers }).distinct()
                dnsServers.forEach { server ->
                    try {
                        builder.addDnsServer(server)
                    } catch (error: Exception) {
                        Log.w("SwockVpnService", "Could not add DNS server $server: ${error.message}")
                    }
                }
                if (dnsServers.isNotEmpty()) {
                    recordVpnEvent(
                        "${if (customDnsServers.isNotEmpty()) "Custom" else "Network"} DNS active: ${dnsServers.joinToString(", ")}",
                    )
                } else {
                    recordVpnEvent("No DNS servers are available on the active network")
                }
                vpnInterface = builder.establish()
                requireNotNull(vpnInterface) { "Unable to establish VPN interface" }
                recordVpnEvent("VPN interface established")
                engine.start(engineProfileJson, vpnInterface!!)
                retries = 0
                currentStatus = engine.getStatus()
                while (shouldRun && engine.getStatus()["state"] == "connected") {
                    currentStatus = engine.getStatus()
                    currentStatistics = engine.getStatistics()
                    try {
                        updateVpnNotification("connected")
                        Thread.sleep(500)
                    } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                        break
                    }
                }
                if (!shouldRun) break
                val failure = engine.getStatus()["message"]?.toString() ?: "Tunnel connection lost"
                throw IllegalStateException(failure)
            } catch (error: Exception) {
                if (!shouldRun) break
                Log.e("SwockVpnService", "VPN connection attempt failed", error)
                if (error is XrayProfileConfigurationException || error is XrayRuntimeException) {
                    shouldRun = false
                    if (error is XrayProfileConfigurationException) {
                        getSharedPreferences(PREFS, MODE_PRIVATE).edit()
                            .remove(PROFILE_KEY)
                            .apply()
                    }
                    engine.stop()
                    closeVpnInterface()
                    releaseStabilityLocks()
                    val detail = error.message?.takeIf { it.isNotBlank() }
                        ?: "Xray-core rejected the imported profile configuration."
                    currentStatus = mapOf(
                        "state" to "error",
                        "connected" to false,
                        "message" to detail,
                    )
                    recordVpnEvent("Xray startup failed: $detail")
                    currentStatistics = engine.getStatistics()
                    updateVpnNotification("error")
                    stopForeground(STOP_FOREGROUND_REMOVE)
                    stopSelf()
                    return
                }
                val engineStatus = engine.getStatus()
                val phase = engineStatus["message"]?.toString()?.takeIf {
                    engineStatus["state"] == "connecting" || engineStatus["state"] == "error"
                } ?: "VPN setup"
                engine.stop()
                closeVpnInterface()
                retries++
                val delaySeconds = minOf(30, 1 shl minOf(retries - 1, 5))
                val detail = error.message?.takeIf { it.isNotBlank() } ?: "no additional detail"
                currentStatus = mapOf(
                    "state" to "reconnecting",
                    "connected" to false,
                    "message" to "Attempt $retries failed during $phase (${error.javaClass.simpleName}: $detail). Retrying in ${delaySeconds}s",
                    "attempt" to retries,
                )
                recordVpnEvent(currentStatus["message"].toString())
                currentStatistics = engine.getStatistics()
                updateVpnNotification("reconnecting")
                synchronized(retryMonitor) {
                    try { retryMonitor.wait(delaySeconds * 1000L) } catch (_: InterruptedException) {
                        Thread.currentThread().interrupt()
                    }
                }
            }
        }
        engine.stop()
        closeVpnInterface()
        releaseStabilityLocks()
        if (!shouldRun) {
            currentStatus = mapOf("state" to "disconnected", "connected" to false, "message" to "Disconnected")
            recordVpnEvent("VPN disconnected")
            currentStatistics = mapOf("downloadBytes" to 0L, "uploadBytes" to 0L, "durationMs" to 0L)
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun stopRequestedByUser() {
        shouldRun = false
        getSharedPreferences(PREFS, MODE_PRIVATE).edit().remove(PROFILE_KEY).apply()
        currentStatus = mapOf("state" to "disconnecting", "connected" to false, "message" to "Disconnecting tunnel")
        recordVpnEvent("User requested VPN stop")
        stopEngineOffMainThread()
        if (worker?.isAlive == true) {
            currentStatus = mapOf("state" to "disconnecting", "connected" to false, "message" to "Disconnecting tunnel")
        }
        synchronized(retryMonitor) { retryMonitor.notifyAll() }
        closeVpnInterface()
        if (worker?.isAlive != true) {
            currentStatus = mapOf("state" to "disconnected", "connected" to false, "message" to "Disconnected")
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    private fun closeVpnInterface() {
        try { vpnInterface?.close() } catch (_: Exception) { }
        vpnInterface = null
    }

    /** TLS socket close can perform network I/O, so keep it off Android's main thread. */
    private fun stopEngineOffMainThread() {
        Thread({
            try {
                engine.stop()
            } catch (error: Exception) {
                Log.w("SwockVpnService", "Error while stopping VPN transport", error)
            }
        }, "swock-engine-stop").apply {
            isDaemon = true
            start()
        }
    }

    private fun isValidIpAddress(ip: String): Boolean {
        return ip.matches(Regex("^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$")) ||
               ip.contains(":")
    }

    private fun getUnderlyingNetwork(): Network? {
        val current = underlyingNetwork
        if (current != null) {
            try {
                val caps = connectivityManager.getNetworkCapabilities(current)
                if (caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    return current
                }
            } catch (_: Exception) { }
        }

        try {
            val active = connectivityManager.activeNetwork
            if (active != null) {
                val caps = connectivityManager.getNetworkCapabilities(active)
                if (caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
                    return active
                }
            }
        } catch (_: Exception) { }

        try {
            return connectivityManager.allNetworks.firstOrNull { candidate ->
                val caps = connectivityManager.getNetworkCapabilities(candidate)
                caps != null && !caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
            }
        } catch (_: Exception) { }

        return null
    }

    private fun networkType(network: Network): String {
        val capabilities = connectivityManager.getNetworkCapabilities(network) ?: return "unknown network"
        return when {
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "Wi-Fi"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
            capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "Ethernet"
            else -> "other network"
        }
    }

    private fun acquireStabilityLocks() {
        releaseStabilityLocks()
        try {
            val wifi = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = wifi.createWifiLock(mode, "swock:stability").apply {
                setReferenceCounted(false)
                acquire()
            }
            val power = getSystemService(POWER_SERVICE) as PowerManager
            cpuLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "swock:stability").apply {
                setReferenceCounted(false)
                acquire(12L * 60 * 60 * 1000)
            }
            recordVpnEvent("Call stability: Wi-Fi low-latency lock and CPU wake lock held")
        } catch (error: Exception) {
            recordVpnEvent("Call stability locks unavailable: ${error.message}")
        }
    }

    private fun releaseStabilityLocks() {
        try { if (wifiLock?.isHeld == true) wifiLock?.release() } catch (_: Exception) { }
        try { if (cpuLock?.isHeld == true) cpuLock?.release() } catch (_: Exception) { }
        wifiLock = null
        cpuLock = null
    }

    override fun onRevoke() {
        stopRequestedByUser()
        super.onRevoke()
    }

    override fun onDestroy() {
        shouldRun = false
        try { connectivityManager.unregisterNetworkCallback(networkCallback) } catch (_: Exception) { }
        synchronized(retryMonitor) { retryMonitor.notifyAll() }
        stopEngineOffMainThread()
        closeVpnInterface()
        releaseStabilityLocks()
        if (currentStatus["state"] != "disconnecting") {
            currentStatus = mapOf("state" to "disconnected", "connected" to false, "message" to "Disconnected")
        }
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("swock_vpn", "Swock VPN", NotificationManager.IMPORTANCE_LOW).apply {
                description = "Shows the current Swock VPN connection while it is in use"
                setShowBadge(false)
            }
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }

    private fun updateVpnNotification(state: String) {
        if (!shouldRun) return
        getSystemService(NotificationManager::class.java).notify(1, buildNotification(state))
    }

    private fun buildNotification(state: String): android.app.Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)?.apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = launchIntent?.let {
            PendingIntent.getActivity(
                this,
                1001,
                it,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        }
        val (label, icon) = when (state) {
            "connected" -> "Connected" to cloudIcon("connected")
            "disconnecting" -> "Disconnecting" to cloudIcon("disconnecting")
            "disconnected" -> "Disconnected" to cloudIcon("disconnected")
            "reconnecting" -> "Reconnecting" to cloudIcon("reconnecting")
            else -> "Connecting" to cloudIcon("connecting")
        }
        return NotificationCompat.Builder(this, "swock_vpn")
            .setSmallIcon(android.R.drawable.stat_sys_warning)
            .setLargeIcon(icon)
            .setContentTitle("Swock · $label")
            .setContentText("VPN is ${label.lowercase()}")
            .setContentIntent(contentIntent)
            .setAutoCancel(false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun cloudIcon(state: String): Bitmap {
        val size = 96
        val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(bitmap)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = android.graphics.Color.WHITE; style = Paint.Style.FILL }
        val cloud = Path().apply {
            moveTo(20f, 62f)
            cubicTo(10f, 62f, 8f, 48f, 18f, 43f)
            cubicTo(18f, 30f, 32f, 23f, 43f, 31f)
            cubicTo(50f, 13f, 76f, 18f, 78f, 41f)
            cubicTo(94f, 44f, 91f, 62f, 77f, 62f)
            close()
        }
        canvas.drawPath(cloud, paint)
        paint.style = Paint.Style.STROKE
        paint.strokeWidth = 5f
        paint.strokeCap = Paint.Cap.ROUND
        paint.strokeJoin = Paint.Join.ROUND
        paint.color = when (state) {
            "connected" -> android.graphics.Color.rgb(37, 220, 130)
            "disconnecting" -> android.graphics.Color.rgb(255, 178, 72)
            else -> android.graphics.Color.rgb(80, 202, 239)
        }
        when (state) {
            "connected" -> {
                canvas.drawLine(31f, 50f, 43f, 58f, paint)
                canvas.drawLine(43f, 58f, 66f, 39f, paint)
            }
            "disconnecting" -> {
                canvas.drawLine(40f, 47f, 56f, 63f, paint)
                canvas.drawLine(56f, 47f, 40f, 63f, paint)
            }
            "connecting" -> {
                canvas.drawLine(33f, 51f, 33f, 58f, paint)
                canvas.drawLine(49f, 46f, 49f, 58f, paint)
                canvas.drawLine(65f, 51f, 65f, 58f, paint)
            }
            "reconnecting" -> {
                canvas.drawLine(31f, 71f, 27f, 80f, paint)
                canvas.drawLine(47f, 71f, 43f, 80f, paint)
                canvas.drawLine(63f, 71f, 59f, 80f, paint)
                paint.style = Paint.Style.FILL
                canvas.drawArc(RectF(36f, 37f, 62f, 62f), 205f, 285f, false, paint)
                paint.style = Paint.Style.STROKE
                canvas.drawLine(58f, 38f, 61f, 48f, paint)
                canvas.drawLine(58f, 38f, 49f, 41f, paint)
            }
            else -> {
                canvas.drawLine(35f, 72f, 30f, 80f, paint)
                canvas.drawLine(49f, 72f, 44f, 80f, paint)
                canvas.drawLine(63f, 72f, 58f, 80f, paint)
            }
        }
        return bitmap
    }
}
