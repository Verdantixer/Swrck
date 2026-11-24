//go:build windows

package tunnel

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestManualTrojanWebSocketTLSConfig(t *testing.T) {
	profile := clientProfile{
		Name:      "trojan-ws-tls",
		Server:    "cdn.example.test",
		Port:      443,
		Protocol:  "trojan",
		Core:      "xray",
		Password:  "test-password",
		Transport: "websocketTls",
		WebSocket: websocketProfile{
			Enabled: true,
			Path:    "/tunnel",
			Host:    "cdn.example.test",
		},
		TLS: tlsProfile{
			Enabled:    true,
			ServerName: "cdn.example.test",
			ALPN:       []string{"h2", "http/1.1"},
		},
	}

	config, err := profile.xrayConfig(31001)
	if err != nil {
		t.Fatal(err)
	}
	outbound := asObject(asArray(config["outbounds"])[0])
	if outbound["protocol"] != "trojan" {
		t.Fatalf("unexpected outbound protocol: %v", outbound["protocol"])
	}
	server := asObject(asArray(asObject(outbound["settings"])["servers"])[0])
	if server["address"] != "cdn.example.test" || testPort(server["port"]) != 443 {
		t.Fatalf("unexpected Trojan server: %#v", server)
	}
	stream := asObject(outbound["streamSettings"])
	if stream["network"] != "ws" || stream["security"] != "tls" {
		t.Fatalf("unexpected stream settings: %#v", stream)
	}
	tls := asObject(stream["tlsSettings"])
	alpn, ok := tls["alpn"].([]string)
	if tls["serverName"] != "cdn.example.test" || !ok || len(alpn) != 2 {
		t.Fatalf("unexpected TLS settings: %#v", tls)
	}
	ws := asObject(stream["wsSettings"])
	if ws["path"] != "/tunnel" || asObject(ws["headers"])["Host"] != "cdn.example.test" {
		t.Fatalf("unexpected WebSocket settings: %#v", ws)
	}
	inbound := asObject(asArray(config["inbounds"])[0])
	if inbound["listen"] != "127.0.0.1" || testPort(inbound["port"]) != 31001 {
		t.Fatalf("Xray SOCKS inbound is not bound to the allocated loopback port: %#v", inbound)
	}
}

func TestFullXrayJSONUsesDynamicLocalSocksAndPreservesRouting(t *testing.T) {
	profile := clientProfile{
		Core: "xray",
		XrayConfig: `{
			// profile comment
			"inbounds": [{"listen":"127.0.0.1","port":10808,"protocol":"socks","settings":{"auth":"noauth","udp":true}}],
			"outbounds": [{"tag":"proxy","protocol":"trojan","settings":{"servers":[{"address":"edge.example.test","port":443,"password":"secret"}]}}],
			"routing": {"rules":[{"type":"field","network":"udp","outboundTag":"proxy"}],},
		}`,
	}
	config, err := profile.xrayConfig(32002)
	if err != nil {
		t.Fatal(err)
	}
	inbound := asObject(asArray(config["inbounds"])[0])
	if testPort(inbound["port"]) != 32002 {
		t.Fatalf("local SOCKS port was not replaced: %#v", inbound)
	}
	rules := asArray(asObject(config["routing"])["rules"])
	rule := asObject(rules[0])
	if rule["outboundTag"] != "proxy" {
		t.Fatalf("Xray routing rule was not preserved: %#v", rule)
	}
}

func TestSingBoxJSONGetsTUNWithoutLosingProfileConfig(t *testing.T) {
	ipv6 := false
	profile := clientProfile{
		Core: "singbox",
		Advanced: struct {
			IPv6Enabled *bool `json:"ipv6Enabled"`
		}{IPv6Enabled: &ipv6},
		XrayConfig: `{
			"inbounds":[{"type":"socks","tag":"local","listen":"127.0.0.1","listen_port":10808}],
			"outbounds":[{"type":"vless","tag":"proxy","server":"edge.example.test","server_port":443}],
			"route":{"final":"proxy","rules":[{"protocol":"dns","action":"hijack-dns"}]},
			"dns":{"servers":[{"type":"udp","tag":"remote","server":"1.1.1.1"}]}
		}`,
	}
	data, err := profile.singBoxConfig()
	if err != nil {
		t.Fatal(err)
	}
	var config map[string]any
	if err := json.Unmarshal(data, &config); err != nil {
		t.Fatal(err)
	}
	inbounds := asArray(config["inbounds"])
	tun := asObject(inbounds[len(inbounds)-1])
	if tun["type"] != "tun" || tun["auto_route"] != false || tun["interface_name"] != singBoxTunName {
		t.Fatalf("unexpected TUN inbound: %#v", tun)
	}
	if addresses := asArray(tun["address"]); len(addresses) != 1 || addresses[0] != tunIPv4Address {
		t.Fatalf("IPv6-disabled TUN address list is incorrect: %#v", addresses)
	}
	route := asObject(config["route"])
	if route["final"] != "proxy" || route["auto_detect_interface"] != true {
		t.Fatalf("Sing-box routing was not preserved or configured: %#v", route)
	}
	if len(asArray(asObject(config["dns"])["servers"])) != 1 {
		t.Fatal("Sing-box DNS settings were not preserved")
	}
}

func TestJSONCParserDoesNotStripCommentMarkersInsideStrings(t *testing.T) {
	config, err := parseJSONConfig(`{"path":"/ws//endpoint","text":"/* literal */",}`)
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := json.Marshal(config)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(string(encoded), "/ws//endpoint") || !strings.Contains(string(encoded), "/* literal */") {
		t.Fatalf("JSON strings were changed while removing comments: %s", encoded)
	}
}

func TestHysteria2UsesXrayHysteriaOutboundShape(t *testing.T) {
	profile := clientProfile{
		Server:   "edge.example.test",
		Port:     443,
		Protocol: "hysteria2",
		Password: "secret",
		TLS:      tlsProfile{ServerName: "edge.example.test"},
	}
	config, err := profile.xrayConfig(33003)
	if err != nil {
		t.Fatal(err)
	}
	outbound := asObject(asArray(config["outbounds"])[0])
	if outbound["protocol"] != "hysteria" {
		t.Fatalf("unexpected Hysteria outbound protocol: %v", outbound["protocol"])
	}
	settings := asObject(outbound["settings"])
	if settings["address"] != profile.Server || testPort(settings["port"]) != profile.Port {
		t.Fatalf("unexpected Hysteria endpoint settings: %#v", settings)
	}
}

func TestXrayEndpointPinningKeepsTLSAndWebSocketHostnames(t *testing.T) {
	config := map[string]any{
		"outbounds": []any{map[string]any{
			"protocol": "trojan",
			"settings": map[string]any{"servers": []any{map[string]any{
				"address": "cdn.example.test", "port": 443,
			}}},
			"streamSettings": map[string]any{
				"network":    "ws",
				"security":   "tls",
				"wsSettings": map[string]any{"path": "/tunnel"},
			},
		}},
	}
	pinXrayEndpoint(config, "cdn.example.test", "203.0.113.10")
	outbound := asObject(asArray(config["outbounds"])[0])
	server := asObject(asArray(asObject(outbound["settings"])["servers"])[0])
	if server["address"] != "203.0.113.10" {
		t.Fatalf("Xray server hostname was not pinned: %#v", server)
	}
	stream := asObject(outbound["streamSettings"])
	if asObject(stream["tlsSettings"])["serverName"] != "cdn.example.test" {
		t.Fatalf("TLS server name was not preserved: %#v", stream["tlsSettings"])
	}
	if asObject(asObject(stream["wsSettings"])["headers"])["Host"] != "cdn.example.test" {
		t.Fatalf("WebSocket host was not preserved: %#v", stream["wsSettings"])
	}
}

func TestUnsupportedProfileReturnsActionableError(t *testing.T) {
	_, err := (clientProfile{Protocol: "unknown", Server: "edge.example.test", Port: 443}).xrayConfig(1)
	if err == nil || !strings.Contains(err.Error(), "Unsupported Xray profile protocol") {
		t.Fatalf("expected an explicit unsupported-protocol error, got %v", err)
	}
}

func testPort(value any) int {
	switch port := value.(type) {
	case int:
		return port
	case float64:
		return int(port)
	default:
		return 0
	}
}
