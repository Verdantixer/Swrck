package com.swock.vpn.swock.networking

import android.net.VpnService
import android.net.Uri
import android.net.ConnectivityManager
import android.net.Network
import android.os.ParcelFileDescriptor
import android.util.Log
import libXray.DialerController
import libXray.LibXray
import org.json.JSONArray
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.Inet4Address
import java.net.Inet6Address
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URL
import java.util.concurrent.atomic.AtomicLong

class XrayProfileConfigurationException(message: String, cause: Throwable? = null) :
    IllegalArgumentException(message, cause)

class XrayRuntimeException(message: String, cause: Throwable? = null) :
    IllegalStateException(message, cause)

/** Xray-core adapter. Profile/share-link parsing is delegated to the bundled upstream core. */
class XrayCoreEngine(
    private val vpnService: VpnService,
    private val underlyingNetwork: () -> Network?,
    private val onStatus: (String, String) -> Unit = { _, _ -> },
    private val onLog: (String) -> Unit = {},
) : VpnEngine {
    companion object {
        private const val API_VERSION = 3
        private const val SOCKS_INBOUND_TAG = "swock-socks"

        private fun parseXrayConfig(text: String): JSONObject = JSONObject(normalizeJsonc(text))

        private fun normalizeJsonc(input: String): String {
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
                            while (index + 1 < source.length && !(source[index] == '*' && source[index + 1] == '/')) {
                                if (source[index] == '\n') clean.append('\n')
                                index++
                            }
                            require(index + 1 < source.length) { "Unterminated comment in Xray JSON." }
                            index += 2
                            continue
                        }
                    }
                }
                clean.append(char)
                index++
            }

            val withoutComments = clean.toString()
            val normalized = StringBuilder()
            quoted = false
            escaped = false
            index = 0
            while (index < withoutComments.length) {
                val char = withoutComments[index]
                if (quoted) {
                    normalized.append(char)
                    if (escaped) escaped = false
                    else if (char == '\\') escaped = true
                    else if (char == '"') quoted = false
                    index++
                    continue
                }
                if (char == '"') {
                    quoted = true
                    normalized.append(char)
                    index++
                    continue
                }
                if (char == ',') {
                    var lookahead = index + 1
                    while (lookahead < withoutComments.length && withoutComments[lookahead].isWhitespace()) lookahead++
                    if (lookahead < withoutComments.length && (withoutComments[lookahead] == '}' || withoutComments[lookahead] == ']')) {
                        index++
                        continue
                    }
                }
                normalized.append(char)
                index++
            }
            return normalized.toString()
        }

        fun validateProfile(profileJson: String): String? = try {
            val profile = JSONObject(profileJson)
            val jsonText = profile.optString("xrayConfig").trim()
            val shareText = profile.optString("xrayShareLink").trim()
            when {
                hasEndpointPortOverride(profile) &&
                    profile.optInt("endpointPortOverride") !in 1..65535 ->
                    "Endpoint port override must be between 1 and 65535."
                jsonText.isEmpty() && shareText.isEmpty() &&
                    profile.optString("protocol").equals("xray", true) ->
                    "Xray profiles need a complete JSON configuration or supported proxy share link."
                jsonText.isNotEmpty() -> {
                    val config = parseXrayConfig(jsonText)
                    if (config.optJSONArray("outbounds")?.length().let { it == null || it == 0 }) {
                        "Xray JSON must contain at least one outbound."
                    } else null
                }
                shareText.isNotEmpty() -> when {
                    profile.optString("server").isBlank() -> "Proxy server address is required."
                    profile.optInt("port") !in 1..65535 -> "Proxy server port must be between 1 and 65535."
                    else -> null
                }
                profile.optString("server").isBlank() -> "Proxy server address is required."
                profile.optInt("port") !in 1..65535 -> "Proxy server port must be between 1 and 65535."
                profile.optString("protocol").lowercase() in setOf("vless", "vmess") && profile.optString("uuid").isBlank() -> "${profile.optString("protocol").uppercase()} UUID is required."
                profile.optString("protocol").lowercase() in setOf("trojan", "shadowsocks") && profile.optString("password").isBlank() -> "${profile.optString("protocol").replaceFirstChar { it.uppercase() }} password is required."
                profile.optString("protocol").equals("hysteria2", true) &&
                    profile.optString("hysteriaObfs").equals("salamander", true) &&
                    profile.optString("hysteriaObfsPassword").isBlank() -> "Hysteria 2 Salamander obfuscation password is required."
                profile.optString("protocol").lowercase() !in setOf("vless", "vmess", "trojan", "shadowsocks", "hysteria2", "socks", "http", "directproxy") -> "Use a supported proxy share link or full Xray JSON for this protocol."
                else -> null
            }
        } catch (error: Exception) {
            error.message?.let { "Invalid Xray profile: $it" } ?: "Invalid Xray profile."
        }

        fun configuredMtu(profileJson: String): Int = try {
            val profile = JSONObject(profileJson)
            val config = profile.optString("xrayConfig").takeIf { it.isNotBlank() }?.let(::parseXrayConfig)
            val inbounds = config?.optJSONArray("inbounds")
            val mtu = inbounds?.let { array ->
                (0 until array.length()).firstNotNullOfOrNull { index ->
                    val inbound = array.optJSONObject(index) ?: return@firstNotNullOfOrNull null
                    if (!inbound.optString("protocol").equals("tun", true)) return@firstNotNullOfOrNull null
                    inbound.optJSONObject("settings")?.optInt("mtu")?.takeIf { it in 576..9000 }
                }
            }
            mtu ?: 1500
        } catch (_: Exception) { 1500 }
    }

    @Volatile private var state = "disconnected"
    @Volatile private var message = "Disconnected"
    @Volatile private var startedAt = 0L
    @Volatile private var metricsUrl: String? = null
    @Volatile private var socksInboundTag = SOCKS_INBOUND_TAG
    @Volatile private var tunBridge: Tun2SocksBridge? = null
    @Volatile private var metricsFailureReported = false
    private val uploadBytes = AtomicLong(0)
    private val downloadBytes = AtomicLong(0)
    private val inactiveDialerController = object : DialerController {
        override fun protectFd(fd: Long): Boolean = false
    }

    override fun start(profileJson: String, tun: ParcelFileDescriptor) {
        try {
            startXray(profileJson, tun)
        } catch (error: LinkageError) {
            stopCoreOnly()
            val failure = XrayProfileConfigurationException(
                "Xray runtime could not load a required native component (${error.javaClass.simpleName}). Check that this device is supported and reinstall the app.",
                error,
            )
            setStatus("error", failure.message ?: "Xray runtime component is unavailable.")
            throw failure
        }
    }

    private fun startXray(profileJson: String, tun: ParcelFileDescriptor) {
        val profile = try {
            JSONObject(profileJson)
        } catch (error: Exception) {
            throw XrayProfileConfigurationException(
                "Xray profile data could not be read: ${error.message ?: "invalid profile JSON"}",
                error,
            )
        }
        val validation = validateProfile(profileJson)
        if (validation != null) throw XrayProfileConfigurationException(validation)
        setStatus("connecting", "Starting Xray-core")

        val socksPort = try {
            ServerSocket(0).use { it.localPort }
        } catch (error: Exception) {
            throw XrayProfileConfigurationException("Could not allocate a local Xray SOCKS port.", error)
        }
        val config = try {
            buildCoreConfig(profile, socksPort)
        } catch (error: Exception) {
            throw XrayProfileConfigurationException(
                error.message?.takeIf { it.isNotBlank() }
                    ?: "The Xray configuration is not supported by this Android client.",
                error,
            )
        }
        val controller = object : DialerController {
            override fun protectFd(fd: Long): Boolean = protectSocket(fd)
        }
        LibXray.registerDialerController(controller)
        dnsServer(profile)?.let { dns ->
            try {
                LibXray.setDNS(controller, dns)
                onLog("Xray-core DNS is bound to the underlying network")
            } catch (error: Exception) {
                onLog("Xray-core DNS binding unavailable: ${error.message ?: "unknown error"}")
            }
        }

        metricsUrl = config.optJSONObject("metrics")?.optString("listen")
            ?.takeIf { it.startsWith("127.0.0.1:") }
            ?.let { "http://$it/debug/vars" }
        metricsFailureReported = false

        val current = invoke("getXrayState", JSONObject())
            .optJSONObject("data")?.optBoolean("running") == true
        if (current) invoke("stopXray", JSONObject())

        val response = try {
            invoke("runXray", JSONObject().put("xrayJson", config.toString()))
        } catch (error: Exception) {
            throw XrayProfileConfigurationException(
                error.message?.takeIf { it.isNotBlank() }
                    ?: "Xray-core could not read the configuration.",
                error,
            )
        }
        if (!response.optBoolean("success")) {
            throw XrayProfileConfigurationException(
                response.optString("error")
                    .ifBlank { "Xray-core rejected this profile configuration." },
            )
        }
        val deadline = System.currentTimeMillis() + 5_000
        while (System.currentTimeMillis() < deadline) {
            val running = invoke("getXrayState", JSONObject())
                .optJSONObject("data")?.optBoolean("running") == true
            if (running) break
            Thread.sleep(100)
        }
        if (invoke("getXrayState", JSONObject()).optJSONObject("data")?.optBoolean("running") != true) {
            throw XrayProfileConfigurationException(
                "Xray-core stopped during startup. Check the profile and its Xray settings.",
            )
        }
        val bridge = Tun2SocksBridge(
            vpnService,
            tun,
            configuredMtu(profileJson),
            socksPort,
            onLog,
            enableIpv6 = AdvancedOptions.from(profile).ipv6Enabled,
        )
        tunBridge = bridge
        try {
            bridge.start()
        } catch (error: Exception) {
            stopCoreOnly()
            throw XrayRuntimeException(
                "Xray core started, but its Android TUN bridge failed: ${error.message ?: error.javaClass.simpleName}",
                error,
            )
        }
        startedAt = System.currentTimeMillis()
        val profileProtocol = when (profile.optString("protocol").lowercase()) {
            "xray" -> "Xray JSON"
            "hysteria2" -> "Hysteria 2"
            "directproxy" -> "Direct proxy"
            else -> profile.optString("protocol").uppercase().ifBlank { "Proxy" }
        }
        setStatus("connected", "$profileProtocol tunnel connected")
        onLog("$profileProtocol is running through Xray-core and the Android VPN interface")
    }

    private fun buildCoreConfig(profile: JSONObject, socksPort: Int): JSONObject {
        val raw = profile.optString("xrayConfig").trim()
        val shareText = profile.optString("xrayShareLink").trim()
        val config = when {
            raw.isNotEmpty() -> parseXrayConfig(raw).also {
                applyEndpointPortOverrideToConfig(it, profile)
            }
            shareText.isNotEmpty() -> {
                val converted = invoke("convertShareLinksToXrayJson", JSONObject().put("text", shareText))
                val outbounds = if (converted.optBoolean("success")) {
                    converted.optJSONObject("data")?.optJSONArray("outbounds") ?: JSONArray()
                } else JSONArray()
                if (outbounds.length() > 0) {
                    val shareOutbounds = JSONArray()
                    var portOverrideApplied = !hasEndpointPortOverride(profile)
                    for (index in 0 until outbounds.length()) {
                        var outbound = outbounds.optJSONObject(index) ?: continue
                        if (!portOverrideApplied &&
                            applyEndpointPortOverrideToOutbound(outbound, profile)
                        ) {
                            portOverrideApplied = true
                        }
                        shareOutbounds.put(
                            if (profile.optJSONObject("webSocket")?.optBoolean("enabled") == true ||
                                profile.optJSONObject("tls")?.optBoolean("enabled") == true ||
                                profile.optString("transport", "auto") != "auto"
                            ) {
                                applyProfileTransport(outbound, profile)
                            } else outbound,
                        )
                    }
                    require(portOverrideApplied) {
                        "Could not apply the selected port to the imported share link."
                    }
                    JSONObject().put("outbounds", shareOutbounds)
                } else if (profile.optString("protocol").equals("vmess", true) ||
                    profile.optString("protocol").equals("hysteria2", true)) {
                    // The upstream share parser accepts VMess AEAD; legacy QR payloads are
                    // already decoded by the Flutter importer and use the regular VMess builder.
                    // Hysteria2 imports retain its standard auth/SNI/obfuscation fields for
                    // the equivalent Xray outbound if a share-link variant is unavailable.
                    JSONObject().put("outbounds", JSONArray().put(buildManualOutbound(profile)))
                } else if (profile.optString("protocol").equals("shadowsocks", true) &&
                    hasShadowsocksTransportOptions(shareText)) {
                    // SS share links can carry WS/TLS extensions that share-link parsers
                    // don't project consistently. The importer stores those in the profile,
                    // so use the regular Xray Shadowsocks outbound with its edited transport.
                    JSONObject().put("outbounds", JSONArray().put(buildManualOutbound(profile)))
                } else {
                    throw IllegalArgumentException(
                        converted.optString("error").ifBlank { "Xray share link is invalid or unsupported." },
                    )
                }
            }
            else -> JSONObject().put("outbounds", JSONArray().put(buildManualOutbound(profile)))
        }

        val outbounds = config.optJSONArray("outbounds")
        require(outbounds != null && outbounds.length() > 0) { "Xray configuration needs at least one outbound." }

        val inbounds = config.optJSONArray("inbounds") ?: JSONArray()
        val retainedInbounds = JSONArray()
        var socksTag: String? = null
        for (index in 0 until inbounds.length()) {
            val inbound = inbounds.optJSONObject(index) ?: continue
            when {
                inbound.optString("protocol").equals("tun", ignoreCase = true) -> {
                    // Android traffic is supplied by Tropical Tunnel's TUN-to-SOCKS bridge.
                }
                inbound.optString("protocol").equals("socks", ignoreCase = true) && socksTag == null -> {
                    val localSocks = JSONObject(inbound.toString())
                    val tag = localSocks.optString("tag").ifBlank { SOCKS_INBOUND_TAG }
                    val settings = localSocks.optJSONObject("settings") ?: JSONObject()
                    settings.put("auth", "noauth")
                        .put("udp", true)
                        .remove("accounts")
                    localSocks.put("listen", "127.0.0.1")
                        .put("port", socksPort)
                        .put("tag", tag)
                        .put("settings", settings)
                    retainedInbounds.put(localSocks)
                    socksTag = tag
                }
                else -> retainedInbounds.put(inbound)
            }
        }
        if (socksTag == null) {
            socksTag = SOCKS_INBOUND_TAG
            retainedInbounds.put(
                JSONObject()
                    .put("tag", socksTag)
                    .put("listen", "127.0.0.1")
                    .put("port", socksPort)
                    .put("protocol", "socks")
                    .put("settings", JSONObject().put("auth", "noauth").put("udp", true)),
            )
        }
        socksInboundTag = socksTag
        config.put("inbounds", retainedInbounds)

        val dnsConfig = config.optJSONObject("dns") ?: JSONObject()
        dnsConfig.put("queryStrategy", "UseIP")
        config.put("dns", dnsConfig)

        val env = config.optJSONObject("env") ?: JSONObject()
        env.remove("xray.tun.fd")
        if (env.length() == 0) config.remove("env") else config.put("env", env)
        installMetrics(config)
        return config
    }

    private fun hasShadowsocksTransportOptions(shareText: String): Boolean = runCatching {
        val uri = Uri.parse(shareText)
        uri.scheme.equals("ss", true) || uri.scheme.equals("shadowsocks", true)
    }.getOrDefault(false) && runCatching {
        val names = Uri.parse(shareText).queryParameterNames
        names.any { it.lowercase() in setOf("type", "network", "security", "sni", "host", "path", "alpn") }
    }.getOrDefault(false)

    /** Keeps native share-link credentials/options while honoring transport values edited in the app. */
    private fun applyProfileTransport(outbound: JSONObject, profile: JSONObject): JSONObject {
        val manualStream = buildManualOutbound(profile).optJSONObject("streamSettings") ?: return outbound
        val result = JSONObject(outbound.toString())
        val stream = result.optJSONObject("streamSettings") ?: JSONObject()
        val transport = profile.optString("transport", "auto")
        val editedNetwork = manualStream.optString("network")
        if (transport != "auto" && editedNetwork.isNotBlank()) {
            stream.put("network", editedNetwork)
            val settingsKey = when (editedNetwork) {
                "ws" -> "wsSettings"
                "httpupgrade" -> "httpupgradeSettings"
                "http" -> "httpSettings"
                "grpc" -> "grpcSettings"
                "xhttp" -> "xhttpSettings"
                else -> null
            }
            if (settingsKey != null) {
                val settings = stream.optJSONObject(settingsKey) ?: JSONObject()
                val editedSettings = manualStream.optJSONObject(settingsKey)
                if (editedSettings != null) {
                    val keys = editedSettings.keys()
                    while (keys.hasNext()) {
                        val key = keys.next()
                        settings.put(key, editedSettings.get(key))
                    }
                    stream.put(settingsKey, settings)
                }
            }
        }

        // The profile editor cannot represent Reality security settings.
        if (!stream.optString("security").equals("reality", ignoreCase = true)) {
            stream.put("security", manualStream.optString("security", "none"))
            val useTls = manualStream.optString("security") == "tls"
            if (useTls) {
                val tlsSettings = stream.optJSONObject("tlsSettings") ?: JSONObject()
                val editedTlsSettings = manualStream.optJSONObject("tlsSettings") ?: JSONObject()
                val keys = editedTlsSettings.keys()
                while (keys.hasNext()) {
                    val key = keys.next()
                    tlsSettings.put(key, editedTlsSettings.get(key))
                }
                stream.put("tlsSettings", tlsSettings)
            } else {
                stream.remove("tlsSettings")
            }
        }

        result.put("streamSettings", stream)
        return result
    }

    private fun buildManualOutbound(profile: JSONObject): JSONObject {
        val protocol = profile.optString("protocol").lowercase()
        val server = profile.optString("server").trim()
        val port = profile.optInt("port")
        val password = profile.optString("password")
        val proxy = profile.optJSONObject("proxy") ?: JSONObject()
        val tls = profile.optJSONObject("tls") ?: JSONObject()
        val ws = profile.optJSONObject("webSocket") ?: JSONObject()
        val transport = profile.optString("transport", "auto")
        val network = when (transport) {
            "tcp" -> "tcp"
            "kcp" -> "kcp"
            "websocket", "websocketTls" -> "ws"
            "httpUpgrade" -> "httpupgrade"
            "http" -> "http"
            "quic" -> "quic"
            "grpc" -> "grpc"
            "xhttp" -> "xhttp"
            else -> if (ws.optBoolean("enabled")) "ws" else null
        }
        val useWs = network == "ws"
        val useTls = tls.optBoolean("enabled") || transport == "websocketTls"
        val stream = JSONObject()
            .put("security", if (useTls) "tls" else "none")
        if (network != null) stream.put("network", network)
        if (useTls) {
            val tlsSettings = JSONObject()
            val sni = tls.optString("sni").ifBlank { server }
            if (sni.isNotBlank()) tlsSettings.put("serverName", sni)
            if (tls.optBoolean("allowInsecureCertificate")) tlsSettings.put("allowInsecure", true)
            val alpn = tls.optJSONArray("alpn")
            if (alpn != null && alpn.length() > 0) tlsSettings.put("alpn", alpn)
            stream.put("tlsSettings", tlsSettings)
        }
        val path = ws.optString("path")
        val host = ws.optString("host").trim()
        if (useWs) {
            val headers = JSONObject()
            host.takeIf { it.isNotBlank() }?.let { headers.put("Host", it) }
            stream.put(
                "wsSettings",
                JSONObject()
                    .put("path", path)
                    .put("headers", headers),
            )
        } else if (network == "httpupgrade") {
            stream.put(
                "httpupgradeSettings",
                JSONObject().put("path", path).apply {
                    host.takeIf { it.isNotBlank() }?.let { put("host", it) }
                },
            )
        } else if (network == "http") {
            stream.put(
                "httpSettings",
                JSONObject().put("path", path).apply {
                    host.takeIf { it.isNotBlank() }?.let { put("host", JSONArray().put(it)) }
                },
            )
        } else if (network == "grpc") {
            val settings = JSONObject().put("serviceName", path)
            host.takeIf { it.isNotBlank() }?.let { settings.put("authority", it) }
            stream.put("grpcSettings", settings)
        } else if (network == "xhttp") {
            val settings = JSONObject().put("path", path)
            host.takeIf { it.isNotBlank() }?.let { settings.put("host", it) }
            val options = ws.optJSONObject("connectionOptions") ?: JSONObject()
            options.optString("mode").takeIf { it.isNotBlank() }?.let { settings.put("mode", it) }
            stream.put("xhttpSettings", settings)
        }

        val settings = JSONObject()
        when (protocol) {
            "vless" -> {
                val user = JSONObject()
                    .put("id", profile.optString("uuid"))
                    .put("encryption", "none")
                profile.optString("flow").takeIf { it.isNotBlank() }?.let { user.put("flow", it) }
                settings.put("vnext", JSONArray().put(JSONObject()
                    .put("address", server)
                    .put("port", port)
                    .put("users", JSONArray().put(user))))
            }
            "vmess" -> {
                val user = JSONObject()
                    .put("id", profile.optString("uuid"))
                    .put("alterId", profile.optInt("alterId"))
                    .put("security", profile.optString("security").ifBlank { "auto" })
                val serverConfig = JSONObject()
                    .put("address", server)
                    .put("port", port)
                    .put("users", JSONArray().put(user))
                settings.put("vnext", JSONArray().put(serverConfig))
            }
            "trojan" -> settings.put("servers", JSONArray().put(JSONObject()
                .put("address", server).put("port", port).put("password", password)))
            "shadowsocks" -> {
                val cipher = profile.optString("cipher").trim()
                require(cipher.isNotBlank()) { "Shadowsocks cipher is required." }
                settings.put("servers", JSONArray().put(JSONObject()
                    .put("address", server).put("port", port)
                    .put("method", cipher)
                    .put("password", password)))
            }
            "hysteria2" -> {
                settings.put("address", server).put("port", port).put("version", 2)
                val tlsSettings = stream.optJSONObject("tlsSettings") ?: JSONObject()
                tlsSettings.put("serverName", tls.optString("sni").ifBlank { server })
                val hysteriaSettings = JSONObject().put("version", 2)
                password.takeIf { it.isNotBlank() }?.let { hysteriaSettings.put("auth", it) }
                stream.put("network", "hysteria")
                    .put("security", "tls")
                    .put("tlsSettings", tlsSettings)
                    .put("hysteriaSettings", hysteriaSettings)
                if (profile.optString("hysteriaObfs").equals("salamander", true)) {
                    val obfsPassword = profile.optString("hysteriaObfsPassword")
                    require(obfsPassword.isNotBlank()) {
                        "Hysteria 2 Salamander obfuscation password is required."
                    }
                    stream.put(
                        "finalmask",
                        JSONObject().put(
                            "udp",
                            JSONArray().put(
                                JSONObject()
                                    .put("type", "salamander")
                                    .put("settings", JSONObject().put("password", obfsPassword)),
                            ),
                        ),
                    )
                }
            }
            "socks", "directproxy" -> {
                val user = JSONObject()
                if (protocol != "directproxy") {
                    proxy.optString("username").takeIf { it.isNotBlank() }?.let { user.put("user", it) }
                    password.ifBlank { proxy.optString("password") }.takeIf { it.isNotBlank() }?.let { user.put("pass", it) }
                }
                val serverConfig = JSONObject().put("address", server).put("port", port)
                if (user.length() > 0) serverConfig.put("users", JSONArray().put(user))
                settings.put("servers", JSONArray().put(serverConfig))
            }
            "http" -> {
                val serverConfig = JSONObject().put("address", server).put("port", port)
                if (proxy.optString("username").isNotBlank()) {
                    serverConfig.put("users", JSONArray().put(JSONObject()
                        .put("user", proxy.optString("username"))
                        .put("pass", password.ifBlank { proxy.optString("password") })))
                }
                settings.put("servers", JSONArray().put(serverConfig))
            }
            else -> throw IllegalArgumentException("Use an Xray share link or full Xray JSON for this protocol.")
        }
        return JSONObject()
            .put("tag", "proxy")
            .put("protocol", when (protocol) {
                "hysteria2" -> "hysteria"
                "directproxy" -> "socks"
                else -> protocol
            })
            .put("settings", settings)
            .put("streamSettings", stream)
    }

    private fun installMetrics(config: JSONObject) {
        val metrics = config.optJSONObject("metrics") ?: JSONObject()
        if (metrics.optString("listen").isBlank()) {
            val port = ServerSocket(0).use { it.localPort }
            metrics.put("listen", "127.0.0.1:$port")
        }
        config.put("metrics", metrics)
        val policy = config.optJSONObject("policy") ?: JSONObject()
        val system = policy.optJSONObject("system") ?: JSONObject()
        system.put("statsInboundUplink", true)
        system.put("statsInboundDownlink", true)
        system.put("statsOutboundUplink", true)
        system.put("statsOutboundDownlink", true)
        policy.put("system", system)
        config.put("policy", policy)
        if (config.optJSONObject("stats") == null) config.put("stats", JSONObject())
    }

    private fun dnsServer(profile: JSONObject): String? {
        val profileDns = profile.optJSONObject("dns")
        val custom = if (profileDns?.optBoolean("enabled", false) == true) {
            listOf("primary", "secondary", "tertiary")
                .firstNotNullOfOrNull { key ->
                    profileDns.optString(key).trim().takeIf { it.isNotEmpty() }
                }
        } else null
        val physicalDns = custom?.takeIf(::isIpAddress) ?: try {
            val network = underlyingNetwork() ?: return null
            val manager = vpnService.getSystemService(ConnectivityManager::class.java)
            manager.getLinkProperties(network)?.dnsServers
                ?.firstOrNull { it is Inet4Address || it is Inet6Address }?.hostAddress
        } catch (_: Exception) { null } ?: return null
        val address = physicalDns.substringBefore('%')
        return when {
            isIpv4Address(address) -> "$address:53"
            isIpv6Address(address) -> "[$address]:53"
            else -> null
        }
    }

    private fun isIpv4Address(value: String): Boolean =
        value.matches(Regex("^(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$"))

    private fun isIpv6Address(value: String): Boolean =
        value.contains(':') && try {
            InetAddress.getByName(value) is Inet6Address
        } catch (_: Exception) {
            false
        }

    private fun isIpAddress(value: String): Boolean =
        isIpv4Address(value) || isIpv6Address(value.substringBefore('%'))

    private fun invoke(method: String, payload: JSONObject): JSONObject {
        val request = JSONObject()
            .put("apiVersion", API_VERSION)
            .put("method", method)
            .put("payload", payload)
        return JSONObject(LibXray.invoke(request.toString()))
    }

    override fun stop() {
        try {
            stopCoreOnly()
        } catch (error: Exception) {
            Log.w("XrayCoreEngine", "Xray stop request failed", error)
        } finally {
            startedAt = 0L
            metricsUrl = null
            setStatus("disconnected", "Disconnected")
        }
    }

    fun forceReconnect(reason: String) {
        setStatus("error", reason)
        stopCoreOnly()
    }

    private fun stopCoreOnly() {
        tunBridge?.stop()
        tunBridge = null
        try { invoke("stopXray", JSONObject()) } catch (_: Exception) { }
        finally { releaseProcessControllers() }
    }

    private fun protectSocket(fd: Long): Boolean {
        if (fd !in 0..Int.MAX_VALUE.toLong()) {
            onLog("Xray supplied an invalid socket descriptor.")
            return false
        }
        val socketFd = fd.toInt()
        val network = underlyingNetwork()
        if (network != null) {
            val descriptor = ParcelFileDescriptor.adoptFd(socketFd)
            try {
                network.bindSocket(descriptor.fileDescriptor)
                return true
            } catch (error: IOException) {
                onLog(
                    "Could not bind an Xray socket to the active network: " +
                        (error.message?.takeIf { it.isNotBlank() } ?: "I/O error"),
                )
            } finally {
                descriptor.detachFd()
            }
        }
        return vpnService.protect(socketFd)
    }

    private fun releaseProcessControllers() {
        try { LibXray.resetDNS() } catch (_: Exception) { }
        try { LibXray.registerDialerController(inactiveDialerController) } catch (_: Exception) { }
    }

    override fun getStatus(): Map<String, Any?> {
        if (state == "connected") {
            val running = try {
                invoke("getXrayState", JSONObject()).optJSONObject("data")?.optBoolean("running") == true
            } catch (_: Exception) { false }
            if (!running) setStatus("error", "Xray-core stopped unexpectedly")
            else if (tunBridge?.isAlive() != true) setStatus("error", "Xray TUN-to-SOCKS bridge stopped unexpectedly")
        }
        return mapOf("state" to state, "connected" to (state == "connected"), "message" to message)
    }

    override fun getStatistics(): Map<String, Any?> {
        readMetrics()
        return mapOf(
            "downloadBytes" to downloadBytes.get(),
            "uploadBytes" to uploadBytes.get(),
            "durationMs" to if (startedAt == 0L) 0L else System.currentTimeMillis() - startedAt,
        )
    }

    private fun readMetrics() {
        val endpoint = metricsUrl
        if (endpoint == null) {
            reportMetricsFailure("Xray traffic metrics endpoint is unavailable.")
            return
        }
        var connection: HttpURLConnection? = null
        try {
            connection = URL(endpoint).openConnection() as HttpURLConnection
            connection.connectTimeout = 250
            connection.readTimeout = 250
            val body = connection.inputStream.bufferedReader().use { it.readText() }
            val stats = JSONObject(body).optJSONObject("stats")
                ?: throw IllegalStateException("Xray metrics response has no stats object.")
            downloadBytes.set(readCounter(stats, "inbound>>>$socksInboundTag>>>traffic>>>downlink"))
            uploadBytes.set(readCounter(stats, "inbound>>>$socksInboundTag>>>traffic>>>uplink"))
            metricsFailureReported = false
        } catch (error: Exception) {
            reportMetricsFailure(
                "Xray traffic metrics unavailable: ${error.message?.takeIf { it.isNotBlank() } ?: error.javaClass.simpleName}",
            )
        } finally {
            connection?.disconnect()
        }
    }

    private fun reportMetricsFailure(message: String) {
        if (!metricsFailureReported) {
            metricsFailureReported = true
            onLog(message)
        }
    }

    private fun readCounter(values: JSONObject, key: String): Long {
        val value = values.opt(key)
        return when (value) {
            is Number -> value.toLong()
            is JSONObject -> value.optLong("value")
            else -> 0L
        }
    }

    private fun setStatus(next: String, text: String) {
        state = next
        message = text
        onStatus(next, text)
    }

    override fun testConnection(profileJson: String): Boolean = validateProfile(profileJson) == null
}

internal fun hasEndpointPortOverride(profile: JSONObject): Boolean =
    profile.has("endpointPortOverride") && !profile.isNull("endpointPortOverride")

internal fun applyEndpointPortOverrideToConfig(config: JSONObject, profile: JSONObject) {
    if (!hasEndpointPortOverride(profile)) return
    val outbounds = config.optJSONArray("outbounds")
        ?: throw IllegalArgumentException("The imported configuration has no outbounds.")
    for (index in 0 until outbounds.length()) {
        val outbound = outbounds.optJSONObject(index) ?: continue
        if (applyEndpointPortOverrideToOutbound(outbound, profile)) return
    }
    throw IllegalArgumentException(
        "Could not apply the selected port to an endpoint in the imported configuration.",
    )
}

internal fun applyEndpointPortOverrideToOutbound(
    outbound: JSONObject,
    profile: JSONObject,
): Boolean {
    if (!hasEndpointPortOverride(profile)) return false
    val port = profile.optInt("endpointPortOverride")
    require(port in 1..65535) { "Endpoint port override must be between 1 and 65535." }
    val server = profile.optString("server").trim()
    val useFirstEndpoint = server.isBlank() ||
        server.equals("Xray configuration", ignoreCase = true)
    val settings = outbound.optJSONObject("settings") ?: return false
    for (key in listOf("vnext", "servers")) {
        val endpoints = settings.optJSONArray(key) ?: continue
        for (index in 0 until endpoints.length()) {
            val endpoint = endpoints.optJSONObject(index) ?: continue
            val address = endpoint.optString("address").trim()
            if (useFirstEndpoint || address.equals(server, ignoreCase = true)) {
                endpoint.put("port", port)
                return true
            }
        }
    }
    val address = settings.optString("address").trim()
    if ((useFirstEndpoint || address.equals(server, ignoreCase = true)) &&
        address.isNotBlank()
    ) {
        settings.put("port", port)
        return true
    }
    return false
}

/** Selects SSH, Sing-box, or Xray-core as the runtime for VPN profiles. */
class ProfileVpnEngine(
    vpnService: VpnService,
    underlyingNetwork: () -> android.net.Network?,
    onStatus: (String, String) -> Unit,
    onLog: (String) -> Unit,
) : VpnEngine {
    private val xray = XrayCoreEngine(vpnService, underlyingNetwork, onStatus, onLog)
    private val singbox = SingboxCoreEngine(vpnService, underlyingNetwork, onStatus, onLog)
    private val ssh = SshVpnEngine(vpnService, underlyingNetwork, onStatus, onLog)
    @Volatile private var active: VpnEngine = xray

    private fun engineFor(profileJson: String): VpnEngine {
        val profile = JSONObject(profileJson)
        val protocol = profile.optString("protocol").lowercase()
        val hasXrayConfig = profile.optString("xrayConfig").isNotBlank()
        val hasXrayLink = profile.optString("xrayShareLink").isNotBlank()
        val singboxCore = profile.optString("core").equals("singbox", ignoreCase = true)
        return when {
            protocol == "ssh" -> ssh
            singboxCore -> singbox
            hasXrayConfig || hasXrayLink -> xray
            protocol in setOf(
                "vless", "vmess", "trojan", "shadowsocks", "hysteria2",
                "socks", "http", "directproxy", "xray",
            ) -> xray
            else -> throw IllegalArgumentException(
                "Unsupported VPN protocol '${protocol.ifBlank { "unknown" }}'. Select SSH, a supported proxy protocol, or import Xray JSON.",
            )
        }
    }

    override fun start(profileJson: String, tun: ParcelFileDescriptor) {
        active = engineFor(profileJson)
        active.start(profileJson, tun)
    }

    override fun stop() {
        active.stop()
    }

    override fun getStatus(): Map<String, Any?> = active.getStatus()
    override fun getStatistics(): Map<String, Any?> = active.getStatistics()
    override fun testConnection(profileJson: String): Boolean = engineFor(profileJson).testConnection(profileJson)

    fun forceReconnect(reason: String) {
        when (active) {
            xray -> xray.forceReconnect(reason)
            singbox -> singbox.stop()
            ssh -> ssh.stop()
        }
    }
}
