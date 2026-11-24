# Configuration format

The app stores profiles in a JSON format compatible with a simple import/export pipeline.

## Example

```json
{
  "version": 1,
  "profile": {
    "name": "My Server",
    "protocol": "shadowsocks",
    "server": "example.com",
    "port": 443,
    "password": "PASSWORD",
    "cipher": "aes-256-gcm",
    "transport": "tcp",
    "tls": {
      "enabled": true,
      "sni": "example.com"
    },
    "webSocket": {
      "enabled": true,
      "path": "/vpn",
      "host": "example.com"
    }
  }
}
```

Imported proxy profiles also store `xrayShareLink`, preserving the source URI or
link list. The legacy `xrayConfig` field stores complete core-native JSON:
Xray JSON when `core` is `xray`, or native Sing-box JSON when `core` is
`singbox`. Xray JSON is handed to Xray-core with its outbounds, DNS, routing,
stream settings, and protocol-specific fields preserved. Sing-box JSON is
handed to libbox with its outbounds, endpoints, DNS, routing, and
protocol-specific fields preserved; the Android adapter supplies one managed
TUN inbound. Core-specific fields remain opaque so configurations can use
features supported by the bundled core without requiring a profile-model update.
The importer also accepts one native Sing-box outbound object and wraps it in a
minimal managed configuration. Share links for AnyTLS, ShadowTLS, TUIC,
Hysteria 1, SOCKS4/4a, and HTTPS are converted to native Sing-box outbounds.
Other bundled-core protocols, including WireGuard, can be imported as native
Sing-box outbound objects or complete Sing-box JSON. Trojan-Go, NaiveProxy, and
Mieru require their separate upstream plugins and are not provided by the
bundled core.

## Validation rules

Imported configurations must be checked before being applied:

- `server` and `port` are required for standard-field profiles; complete core JSON may contain endpoint data without profile-level values
- Profile-level `port` values must be valid integers between 1 and 65535
- For imported links and Xray JSON, changing the profile editor's port stores
  an `endpointPortOverride`; editing the source link or JSON clears that
  override, so the edited source port is used instead
- Share links must include an explicit endpoint port; the importer preserves it
  and does not infer a protocol default when it is missing
- Legacy native Swock profiles are migrated to the Xray JSON editor and must be replaced with a supported proxy link or Xray configuration before connecting
- SSH profiles use a local SOCKS5 listener carried over standard SSH
  `direct-tcpip` channels; no remote executable path, root permission, or
  server-side TUN helper is required. The SSH account must be allowed to open
  TCP forwarding channels. DNS is tunneled over TCP; other UDP traffic is
  optional and requires a BadVPN UDPGW listener on the SSH server, configured
  through Advanced Options.
- Xray profiles accept supported share links, protocol fields, or complete Xray JSON with at least one outbound. Sing-box profiles accept supported proxy links, one native Sing-box outbound, or complete native Sing-box JSON with at least one outbound. Native JSON is validated by the selected bundled core at connection-test/startup time.
- Native Sing-box JSON may omit a TUN inbound; the Android adapter adds one. If it contains more than one TUN inbound, the app rejects it because the Android VPN service exposes one TUN interface.
- Xray transport modes can be detected from imported links/JSON or selected in
  the standard editor: `tcp`, `kcp`, `ws`, `httpupgrade`, `http`, `quic`,
  `grpc`, and `xhttp`. `auto` preserves the imported transport.
- Transport paths start empty unless supplied by an imported profile/JSON or
  entered manually; the editor does not substitute `/`.
- Sing-box conversion supports `ws`, `httpupgrade`, `http`, and `grpc`.
  Select the Xray core for Xray `kcp`, `quic`, or `xhttp` transports.
- TLS and transport are independent layers; WebSocket with TLS uses WSS
- TLS certificates must be valid for the configured SNI and trusted by Android
- JSON must parse correctly
- malformed or missing values must produce a clear error

## Security note

Protected configuration files may encrypt the sensitive section with authenticated encryption. The app must never store export passwords in plain text.
