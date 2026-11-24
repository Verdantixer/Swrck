package com.swock.vpn.swock.networking

import android.content.pm.PackageManager
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Base64
import io.nekohasekai.libbox.*
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet6Address
import java.net.InetAddress
import java.net.URI

class SingboxCoreEngine(
    private val vpnService: VpnService,
    private val underlyingNetwork: () -> Network?,
    private val onStatus: (String, String) -> Unit = { _, _ -> },
    private val onLog: (String) -> Unit = {},
) : VpnEngine, CommandServerHandler, PlatformInterface {
    @Volatile private var state = "disconnected"
    @Volatile private var message = "Disconnected"
    @Volatile private var commandServer: CommandServer? = null
    @Volatile private var startedAt = 0L
    private var tun: ParcelFileDescriptor? = null

    companion object {
        @Volatile private var setupCompleted = false

        fun configuredMtu(profileJson: String): Int {
            return try {
                val profile = JSONObject(profileJson)
                val config = JSONObject(profile.optString("xrayConfig"))
                val inbounds = config.optJSONArray("inbounds") ?: return 1500
                (0 until inbounds.length()).firstNotNullOfOrNull { index ->
                    val inbound = inbounds.optJSONObject(index)
                        ?: return@firstNotNullOfOrNull null
                    if (!inbound.optString("type").equals("tun", ignoreCase = true)) {
                        return@firstNotNullOfOrNull null
                    }
                    inbound.optInt("mtu", 1500).takeIf { it in 576..9000 }
                } ?: 1500
            } catch (_: Exception) {
                1500
            }
        }

        fun validateProfile(profileJson: String): String? {
            return try {
                val profile = JSONObject(profileJson)
                val protocol = profile.optString("protocol", "xray").lowercase()
                val config = profile.optString("xrayConfig").trim()
                val share = profile.optString("xrayShareLink").trim()
                if (hasEndpointPortOverride(profile) &&
                    profile.optInt("endpointPortOverride") !in 1..65535
                ) {
                    "Endpoint port override must be between 1 and 65535."
                } else if (protocol == "ssh") {
                    "Sing-box does not replace the native SSH tunnel."
                } else if (config.isNotEmpty()) {
                    null
                } else if (profile.optString("server").isBlank()) {
                    "Profile server is missing"
                } else if (profile.optInt("port") !in 1..65535) {
                    "Profile server port must be between 1 and 65535"
                } else null
            } catch (_: Exception) {
                "Profile data could not be read"
            }
        }
    }

    private fun setStatus(next: String, text: String) {
        state = next
        message = text
        onStatus(next, text)
    }

    private fun setupLibbox() {
        synchronized(SingboxCoreEngine::class.java) {
            if (setupCompleted) return
            val options = SetupOptions().apply {
                basePath = vpnService.filesDir.absolutePath
                workingPath = vpnService.filesDir.absolutePath
                tempPath = vpnService.cacheDir.absolutePath
                fixAndroidStack = true
                logMaxLines = 3000
                debug = false
                crashReportSource = "Swock"
                appVersion = try {
                    vpnService.packageManager
                        .getPackageInfo(vpnService.packageName, 0)
                        .longVersionCode
                        .toString()
                } catch (_: PackageManager.NameNotFoundException) { "1" }
                appMarketingVersion = try {
                    vpnService.packageManager
                        .getPackageInfo(vpnService.packageName, 0)
                        .versionName ?: "unknown"
                } catch (_: PackageManager.NameNotFoundException) { "unknown" }
                platformMetadata = JSONObject()
                    .put("os", "Android ${Build.VERSION.RELEASE}")
                    .put("sdk", Build.VERSION.SDK_INT)
                    .put("manufacturer", Build.MANUFACTURER)
                    .put("model", Build.MODEL)
                    .toString()
            }
            Libbox.setup(options)
            setupCompleted = true
        }
    }

    override fun start(profileJson: String, tun: ParcelFileDescriptor) {
        this.tun = tun
        setStatus("connecting", "Starting Sing-box")
        try {
            setupLibbox()
            val config = buildSingboxConfig(JSONObject(profileJson))
            Libbox.checkConfig(config)
            val server = CommandServer(this, this)
            server.start()
            commandServer = server
            server.startOrReloadService(config, OverrideOptions().apply {
                autoRedirect = false
            })
            startedAt = System.currentTimeMillis()
            setStatus("connected", "Secure tunnel is active via Sing-box")
            onLog("Sing-box core active")
        } catch (error: Exception) {
            setStatus("error", "Sing-box failed: ${error.message ?: "unknown error"}")
            throw error
        }
    }

    override fun stop() {
        try {
            commandServer?.closeService()
            commandServer?.close()
        } catch (_: Exception) {
        } finally {
            commandServer = null
            startedAt = 0L
            setStatus("disconnected", "Disconnected")
        }
    }

    override fun getStatus(): Map<String, Any?> = mapOf(
        "state" to state,
        "connected" to (state == "connected"),
        "message" to message,
    )

    override fun getStatistics(): Map<String, Any?> = mapOf(
        "uplink" to 0L,
        "downlink" to 0L,
        "uploadBytes" to 0L,
        "downloadBytes" to 0L,
        "durationMs" to if (startedAt > 0) System.currentTimeMillis() - startedAt else 0L,
    )

    override fun testConnection(profileJson: String): Boolean =
        validateProfile(profileJson) == null && try {
            Libbox.checkConfig(buildSingboxConfig(JSONObject(profileJson)))
            true
        } catch (_: Exception) {
            false
        }

    private fun buildSingboxConfig(profile: JSONObject): String {
        val ipv6Enabled = AdvancedOptions.from(profile).ipv6Enabled
        val xrayConfig = profile.optString("xrayConfig").trim()
        val outbound = if (xrayConfig.isNotEmpty()) {
            val config = JSONObject(normalizeJsonObject(xrayConfig))
            if (isNativeSingboxConfig(config)) {
                return prepareNativeSingboxConfig(
                    config,
                    configuredMtu(profile.toString()),
                    ipv6Enabled,
                )
            }
            applyEndpointPortOverrideToConfig(config, profile)
            convertXrayOutbound(config)
        } else {
            buildProfileOutbound(profile)
        }

        val outbounds = JSONArray().apply {
            put(JSONObject().put("type", "direct").put("tag", "direct"))
            put(outbound)
        }
        val config = JSONObject()
            .put("log", JSONObject().put("level", "info").put("timestamp", true))
            .put("dns", JSONObject()
                .put("servers", JSONArray().put("local"))
                .put("strategy", "prefer_ipv4"))
            .put("inbounds", JSONArray().put(JSONObject()
                .put("type", "tun")
                .put("tag", "tun-in")
                .put("address", tunAddresses(ipv6Enabled))
                .put("mtu", 1500)
                .put("auto_route", true)
                .put("strict_route", true)))
            .put("outbounds", outbounds)
            .put("route", JSONObject()
                .put("auto_detect_interface", true)
                .put("final", outbound.optString("tag", "proxy")))
        if (!ipv6Enabled) addIpv6BlockRule(config, outbounds)
        return config.toString()
    }

    private fun isNativeSingboxConfig(config: JSONObject): Boolean {
        val outbounds = config.optJSONArray("outbounds") ?: return false
        return (0 until outbounds.length()).any { index ->
            val outbound = outbounds.optJSONObject(index) ?: return@any false
            outbound.has("type")
        }
    }

    private fun prepareNativeSingboxConfig(
        config: JSONObject,
        mtu: Int,
        ipv6Enabled: Boolean,
    ): String {
        val outbounds = config.optJSONArray("outbounds")
            ?: throw IllegalArgumentException("Sing-box JSON must contain an outbounds array.")
        require(outbounds.length() > 0) { "Sing-box JSON must contain at least one outbound." }

        val rawInbounds = config.opt("inbounds")
        require(rawInbounds == null || rawInbounds is JSONArray) {
            "Sing-box JSON inbounds must be an array."
        }
        val inbounds = rawInbounds as? JSONArray ?: JSONArray()
        val tunInbounds = (0 until inbounds.length()).mapNotNull { index ->
            inbounds.optJSONObject(index)?.takeIf {
                it.optString("type").equals("tun", ignoreCase = true)
            }
        }
        require(tunInbounds.size <= 1) {
            "The Android VPN service supports one Sing-box TUN inbound."
        }
        if (tunInbounds.isEmpty()) {
            inbounds.put(
                JSONObject()
                    .put("type", "tun")
                    .put("tag", "tun-in")
                    .put("address", tunAddresses(ipv6Enabled))
                    .put("mtu", mtu)
                    .put("auto_route", true)
                    .put("strict_route", true),
            )
        } else {
            tunInbounds.single()
                .put("address", tunAddresses(ipv6Enabled))
                .put("mtu", mtu)
                .put("auto_route", true)
                .put("strict_route", true)
        }
        config.put("inbounds", inbounds)

        val rawRoute = config.opt("route")
        require(rawRoute == null || rawRoute is JSONObject) {
            "Sing-box JSON route must be an object."
        }
        val route = rawRoute as? JSONObject ?: JSONObject()
        if (route.optString("final").isBlank()) {
            val defaultOutbound = (0 until outbounds.length())
                .mapNotNull { outbounds.optJSONObject(it) }
                .firstOrNull {
                    it.optString("type") !in setOf("direct", "block", "dns", "reject", "drop")
                }
                ?: (0 until outbounds.length())
                    .mapNotNull { outbounds.optJSONObject(it) }
                    .firstOrNull()
                ?: throw IllegalArgumentException(
                    "Sing-box JSON must contain at least one outbound.",
                )
            val defaultTag = defaultOutbound.optString("tag").ifBlank {
                var candidate = "vpn-default"
                var suffix = 1
                while ((0 until outbounds.length()).any {
                        outbounds.optJSONObject(it)?.optString("tag") == candidate
                    }
                ) {
                    candidate = "vpn-default-${suffix++}"
                }
                defaultOutbound.put("tag", candidate)
                candidate
            }
            route.put("final", defaultTag)
        }
        if (!route.has("auto_detect_interface")) {
            route.put("auto_detect_interface", true)
        }
        config.put("route", route)
        if (!ipv6Enabled) addIpv6BlockRule(config, outbounds)
        return config.toString()
    }

    private fun tunAddresses(ipv6Enabled: Boolean): JSONArray =
        JSONArray().put("26.26.26.1/30").apply {
            if (ipv6Enabled) put("fd26:26:26::1/126")
        }

    private fun addIpv6BlockRule(config: JSONObject, outbounds: JSONArray) {
        val outboundTags = (0 until outbounds.length()).mapNotNull { index ->
            outbounds.optJSONObject(index)?.optString("tag")
        }.toSet()
        var blockTag = "swock-ipv6-block"
        var suffix = 1
        while (blockTag in outboundTags) {
            blockTag = "swock-ipv6-block-${suffix++}"
        }
        outbounds.put(JSONObject().put("type", "block").put("tag", blockTag))
        config.put("outbounds", outbounds)

        val rawRoute = config.opt("route")
        require(rawRoute == null || rawRoute is JSONObject) {
            "Sing-box JSON route must be an object."
        }
        val route = rawRoute as? JSONObject ?: JSONObject()
        val rawRules = route.opt("rules")
        require(rawRules == null || rawRules is JSONArray) {
            "Sing-box route rules must be an array."
        }
        val rules = rawRules as? JSONArray ?: JSONArray()
        val blockedRules = JSONArray().put(
            JSONObject()
                .put("ip_version", 6)
                .put("outbound", blockTag),
        )
        for (index in 0 until rules.length()) {
            blockedRules.put(rules.get(index))
        }
        route.put("rules", blockedRules)
        config.put("route", route)
    }

    private fun normalizeJsonObject(input: String): String {
        val source = input.removePrefix("\uFEFF")
        val clean = StringBuilder()
        var quoted = false
        var escaped = false
        var index = 0
        while (index < source.length) {
            val char = source[index]
            if (quoted) {
                clean.append(char)
                if (escaped) escaped = false
                else if (char == '\\') escaped = true
                else if (char == '"') quoted = false
                index++
                continue
            }
            if (char == '"') {
                quoted = true
                clean.append(char)
                index++
                continue
            }
            if (char == '/' && index + 1 < source.length) {
                when (source[index + 1]) {
                    '/' -> {
                        index += 2
                        while (index < source.length && source[index] != '\n') index++
                        continue
                    }
                    '*' -> {
                        index += 2
                        while (index + 1 < source.length &&
                            !(source[index] == '*' && source[index + 1] == '/')) index++
                        require(index + 1 < source.length) { "Unterminated Xray JSON comment." }
                        index += 2
                        continue
                    }
                }
            }
            clean.append(char)
            index++
        }
        return clean.toString()
    }

    private fun convertXrayOutbound(config: JSONObject): JSONObject {
        val outbounds = config.optJSONArray("outbounds") ?: return buildProfileOutbound(JSONObject())
        for (index in 0 until outbounds.length()) {
            val outbound = outbounds.optJSONObject(index) ?: continue
            val protocol = outbound.optString("protocol").lowercase()
            if (protocol in setOf("vless", "vmess", "trojan", "shadowsocks", "hysteria", "hysteria2", "socks", "http")) {
                val settings = outbound.optJSONObject("settings") ?: JSONObject()
                val stream = outbound.optJSONObject("streamSettings") ?: JSONObject()
                return convertOutbound(protocol, settings, stream)
            }
        }
        throw IllegalArgumentException("The Xray JSON does not contain a supported Sing-box outbound.")
    }

    private fun convertOutbound(protocol: String, settings: JSONObject, stream: JSONObject): JSONObject {
        val result = JSONObject().put("tag", "proxy")
        when (protocol) {
            "vless" -> {
                val endpoint = settings.optJSONArray("vnext")?.optJSONObject(0) ?: throw IllegalArgumentException("Invalid VLESS endpoint.")
                val user = endpoint.optJSONArray("users")?.optJSONObject(0) ?: JSONObject()
                result.put("type", "vless")
                    .put("server", endpoint.optString("address"))
                    .put("server_port", endpoint.optInt("port"))
                    .put("uuid", user.optString("id"))
                if (user.optString("flow").isNotEmpty()) result.put("flow", user.optString("flow"))
            }
            "vmess" -> {
                val endpoint = settings.optJSONArray("vnext")?.optJSONObject(0) ?: throw IllegalArgumentException("Invalid VMess endpoint.")
                val user = endpoint.optJSONArray("users")?.optJSONObject(0) ?: JSONObject()
                result.put("type", "vmess")
                    .put("server", endpoint.optString("address"))
                    .put("server_port", endpoint.optInt("port"))
                    .put("uuid", user.optString("id"))
                    .put("security", user.optString("security", "auto"))
                    .put("alter_id", user.optInt("alterId"))
            }
            "trojan" -> {
                val server = settings.optJSONArray("servers")?.optJSONObject(0) ?: throw IllegalArgumentException("Invalid Trojan endpoint.")
                result.put("type", "trojan")
                    .put("server", server.optString("address"))
                    .put("server_port", server.optInt("port"))
                    .put("password", server.optString("password"))
            }
            "shadowsocks" -> {
                val server = settings.optJSONArray("servers")?.optJSONObject(0) ?: throw IllegalArgumentException("Invalid Shadowsocks endpoint.")
                result.put("type", "shadowsocks")
                    .put("server", server.optString("address"))
                    .put("server_port", server.optInt("port"))
                    .put("method", server.optString("method"))
                    .put("password", server.optString("password"))
            }
            "hysteria", "hysteria2" -> {
                result.put("type", "hysteria2")
                    .put("server", settings.optString("address"))
                    .put("server_port", settings.optInt("port"))
                    .put("password", settings.optString("auth").ifBlank { settings.optString("password") })
            }
            "socks" -> {
                val server = settings.optJSONArray("servers")?.optJSONObject(0)
                    ?: throw IllegalArgumentException("Invalid SOCKS endpoint.")
                result.put("type", "socks")
                    .put("server", server.optString("address"))
                    .put("server_port", server.optInt("port"))
                val users = server.optJSONArray("users")?.optJSONObject(0)
                if (users != null) result.put("username", users.optString("user")).put("password", users.optString("pass"))
            }
            "http" -> {
                val server = settings.optJSONArray("servers")?.optJSONObject(0)
                    ?: throw IllegalArgumentException("Invalid HTTP endpoint.")
                result.put("type", "http")
                    .put("server", server.optString("address"))
                    .put("server_port", server.optInt("port"))
            }
        }
        applyTransport(result, stream)
        return result
    }

    private fun buildProfileOutbound(profile: JSONObject): JSONObject {
        val protocol = profile.optString("protocol", "xray").lowercase()
        val server = profile.optString("server").trim()
        val port = profile.optInt("port")
        val result = JSONObject().put("tag", "proxy").put("server", server).put("server_port", port)
        val ws = profile.optJSONObject("webSocket") ?: JSONObject()
        val tls = profile.optJSONObject("tls") ?: JSONObject()

        when (protocol) {
            "vless" -> {
                result.put("type", "vless").put("uuid", profile.optString("uuid"))
                if (profile.optString("flow").isNotEmpty()) result.put("flow", profile.optString("flow"))
            }
            "vmess" -> result.put("type", "vmess")
                .put("uuid", profile.optString("uuid"))
                .put("security", profile.optString("security", "auto"))
                .put("alter_id", profile.optInt("alterId"))
            "trojan" -> result.put("type", "trojan").put("password", profile.optString("password"))
            "shadowsocks" -> result.put("type", "shadowsocks")
                .put("method", profile.optString("cipher"))
                .put("password", profile.optString("password"))
            "hysteria2" -> result.put("type", "hysteria2")
                .put("password", profile.optString("password"))
            "socks", "directproxy" -> {
                result.put("type", "socks")
                val proxy = profile.optJSONObject("proxy") ?: JSONObject()
                val username = proxy.optString("username")
                if (username.isNotEmpty()) {
                    result.put("username", username).put("password", profile.optString("password"))
                }
            }
            "http" -> {
                result.put("type", "http")
                val proxy = profile.optJSONObject("proxy") ?: JSONObject()
                val username = proxy.optString("username")
                if (username.isNotEmpty()) {
                    result.put("username", username).put("password", profile.optString("password"))
                }
            }
            "xray" -> throw IllegalArgumentException("Sing-box requires an Xray JSON outbound or supported share-link fields.")
            else -> throw IllegalArgumentException("Protocol '$protocol' is not supported by Sing-box.")
        }

        val transportMode = profile.optString("transport", "auto")
        val network = when (transportMode) {
            "tcp" -> "tcp"
            "kcp" -> "kcp"
            "websocket", "websocketTls" -> "ws"
            "httpUpgrade" -> "httpupgrade"
            "http" -> "http"
            "quic" -> "quic"
            "grpc" -> "grpc"
            "xhttp" -> "xhttp"
            else -> if (ws.optBoolean("enabled")) "ws" else "tcp"
        }
        val path = ws.optString("path")
        val host = ws.optString("host").trim()
        val stream = JSONObject().apply {
            put("network", network)
            if (tls.optBoolean("enabled")) put("security", "tls")
            when (network) {
                "ws" -> {
                    val headers = JSONObject(ws.optJSONObject("headers")?.toString() ?: "{}")
                    if (host.isNotBlank()) headers.put("Host", host)
                    put("wsSettings", JSONObject().put("path", path).put("headers", headers))
                }
                "httpupgrade" -> put("httpupgradeSettings", JSONObject().put("path", path).apply {
                    if (host.isNotBlank()) put("host", host)
                })
                "http" -> put("httpSettings", JSONObject().put("path", path).apply {
                    if (host.isNotBlank()) put("host", JSONArray().put(host))
                })
                "grpc" -> if (path.isNotEmpty()) put("grpcSettings", JSONObject().put("serviceName", path))
                "xhttp" -> put("xhttpSettings", JSONObject().put("path", path).apply {
                    if (host.isNotBlank()) put("host", host)
                    val options = ws.optJSONObject("connectionOptions") ?: JSONObject()
                    options.optString("mode").takeIf { it.isNotBlank() }?.let { put("mode", it) }
                })
            }
            if (tls.optBoolean("enabled")) put("tlsSettings", JSONObject()
                .put("serverName", tls.optString("serverName").ifBlank { tls.optString("sni").ifBlank { server } }))
        }
        applyTransport(result, stream)
        return result
    }

    private fun applyTransport(result: JSONObject, stream: JSONObject) {
        val network = stream.optString("network", "tcp").lowercase()
        when (network) {
            "ws", "websocket" -> {
                val ws = stream.optJSONObject("wsSettings") ?: JSONObject()
                val transport = JSONObject()
                    .put("type", "ws")
                    .put("headers", ws.optJSONObject("headers") ?: JSONObject())
                if (ws.has("path")) transport.put("path", ws.optString("path"))
                result.put("transport", transport)
            }
            "grpc" -> {
                val grpc = stream.optJSONObject("grpcSettings") ?: JSONObject()
                val transport = JSONObject().put("type", "grpc")
                if (grpc.has("serviceName")) {
                    transport.put("service_name", grpc.optString("serviceName"))
                }
                result.put("transport", transport)
            }
            "httpupgrade" -> {
                val httpUpgrade = stream.optJSONObject("httpupgradeSettings") ?: JSONObject()
                val transport = JSONObject().put("type", "httpupgrade")
                if (httpUpgrade.has("host")) transport.put("host", httpUpgrade.optString("host"))
                if (httpUpgrade.has("path")) transport.put("path", httpUpgrade.optString("path"))
                result.put("transport", transport)
            }
            "http" -> {
                val http = stream.optJSONObject("httpSettings") ?: JSONObject()
                val transport = JSONObject().put("type", "http")
                if (http.has("host")) transport.put("host", http.optJSONArray("host") ?: JSONArray())
                if (http.has("path")) transport.put("path", http.optString("path"))
                result.put("transport", transport)
            }
            "tcp", "hysteria" -> Unit
            "kcp", "quic", "xhttp" -> throw IllegalArgumentException(
                "Xray transport '$network' is not supported by Sing-box. Select the Xray core for this profile.",
            )
            else -> throw IllegalArgumentException(
                "Xray transport '$network' cannot be converted to Sing-box.",
            )
        }
        val security = stream.optString("security")
        if (security == "tls") {
            val tls = stream.optJSONObject("tlsSettings") ?: JSONObject()
            result.put("tls", JSONObject()
                .put("enabled", true)
                .put("server_name", tls.optString("serverName")))
        }
    }

    // PlatformInterface
    override fun autoDetectInterfaceControl(fd: Int) {
        vpnService.protect(fd)
    }
    override fun cancelNotification(identifier: String, typeID: Int) {}
    override fun checkPlatformShell() {}
    override fun clearDNSCache() {}
    override fun closeDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}
    override fun closeNeighborMonitor(listener: NeighborUpdateListener) {}
    override fun createBridge(options: BridgeOptions): BridgeSession =
        throw UnsupportedOperationException("Sing-box bridge mode is not used by the Android VPN service.")
    override fun findConnectionOwner(ipProtocol: Int, sourceAddress: String, sourcePort: Int, destinationAddress: String, destinationPort: Int): ConnectionOwner =
        Libbox.findConnectionOwner(ipProtocol, sourceAddress, sourcePort, destinationAddress, destinationPort)
    override fun getInterfaces(): NetworkInterfaceIterator = EmptyNetworkInterfaceIterator()
    override fun includeAllNetworks(): Boolean = true
    override fun localDNSTransport(): LocalDNSTransport? = null
    override fun lookupSFTPServer(): String = ""
    override fun lookupUser(name: String): PlatformUser? = null
    override fun openShellSession(user: PlatformUser, path: String, environment: StringIterator, workingDirectory: String, terminalRows: Int, terminalColumns: Int): ShellSession =
        throw UnsupportedOperationException("Shell sessions are not available.")
    override fun openTun(options: TunOptions): Int {
        val activeTun = tun ?: throw IllegalStateException("VPN tun fd is unavailable.")
        return activeTun.fd
    }
    override fun readSystemSSHHostKey(): String = ""
    override fun readWIFIState(): WIFIState = WIFIState("", "")
    override fun registerMyInterface(name: String) {}
    override fun sendNotification(notification: Notification) {}
    override fun startDefaultInterfaceMonitor(listener: InterfaceUpdateListener) {}
    override fun startNeighborMonitor(listener: NeighborUpdateListener) {}
    override fun tailscaleHostname(): String = vpnService.packageName
    override fun underNetworkExtension(): Boolean = false
    override fun usePlatformAutoDetectInterfaceControl(): Boolean = true
    override fun usePlatformBridge(): Boolean = false
    override fun usePlatformShell(): Boolean = false

    // CommandServerHandler
    override fun connectSSHAgent(): Int = -1
    override fun getSystemProxyStatus(): SystemProxyStatus = SystemProxyStatus()
    override fun serviceReload() {}
    override fun serviceStop() {
        stop()
    }
    override fun setSystemProxyEnabled(enabled: Boolean) {}
    override fun triggerNativeCrash() {}
    override fun writeDebugMessage(message: String) {
        onLog(message)
    }

    private class EmptyNetworkInterfaceIterator : NetworkInterfaceIterator {
        override fun hasNext(): Boolean = false
        override fun next(): NetworkInterface = throw NoSuchElementException()
    }
}
