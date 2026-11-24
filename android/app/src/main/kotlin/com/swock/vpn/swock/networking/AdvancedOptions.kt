package com.swock.vpn.swock.networking

import org.json.JSONObject

/** User-selected options passed to the native VPN engines. */
data class AdvancedOptions(
    val callStability: Boolean = false,
    val udpGatewayEnabled: Boolean = false,
    val udpGatewayPort: Int = 7200,
    val ipv6Enabled: Boolean = true,
) {
    fun summary(): String = listOfNotNull(
        "call stability".takeIf { callStability },
        "IPv6 disabled".takeIf { !ipv6Enabled },
    ).joinToString(", ")

    companion object {
        fun from(profile: JSONObject): AdvancedOptions {
            val advanced = profile.optJSONObject("advanced") ?: return AdvancedOptions()
            return AdvancedOptions(
                callStability = advanced.optBoolean("callStability", false),
                udpGatewayEnabled = advanced.optBoolean("udpGatewayEnabled", false),
                udpGatewayPort = advanced.optInt("udpGatewayPort", 7200)
                    .takeIf { it in 1..65535 } ?: 7200,
                ipv6Enabled = advanced.optBoolean("ipv6Enabled", true),
            )
        }
    }
}
