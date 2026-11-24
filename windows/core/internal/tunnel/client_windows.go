//go:build windows

package tunnel

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	singBoxTunName = "Swock VPN"
	tunIPv4Address = "172.19.0.1/30"
	tunIPv6Address = "fdfe:dcba:9876::1/126"
)

type clientProfile struct {
	Name                 string           `json:"name"`
	Server               string           `json:"server"`
	Port                 int              `json:"port"`
	UUID                 string           `json:"uuid"`
	AlterID              int              `json:"alterId"`
	Flow                 string           `json:"flow"`
	Security             string           `json:"security"`
	Protocol             string           `json:"protocol"`
	Core                 string           `json:"core"`
	Cipher               string           `json:"cipher"`
	Password             string           `json:"password"`
	HysteriaObfs         string           `json:"hysteriaObfs"`
	HysteriaObfsPassword string           `json:"hysteriaObfsPassword"`
	Transport            string           `json:"transport"`
	WebSocket            websocketProfile `json:"webSocket"`
	TLS                  tlsProfile       `json:"tls"`
	Proxy                proxyProfile     `json:"proxy"`
	XrayConfig           string           `json:"xrayConfig"`
	EndpointPortOverride *int             `json:"endpointPortOverride"`
	Advanced             struct {
		IPv6Enabled *bool `json:"ipv6Enabled"`
	} `json:"advanced"`
}

type proxyProfile struct {
	Type     string `json:"type"`
	Host     string `json:"host"`
	Port     int    `json:"port"`
	Username string `json:"username"`
	Password string `json:"password"`
}

type supervisedProcess struct {
	name   string
	cmd    *exec.Cmd
	done   chan struct{}
	err    error
	output processOutput
}

type processOutput struct {
	mu    sync.Mutex
	lines []string
}

func (p *processOutput) add(line string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.lines = append(p.lines, line)
	if len(p.lines) > 20 {
		p.lines = append([]string(nil), p.lines[len(p.lines)-20:]...)
	}
}

func (p *processOutput) tail() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	return strings.Join(p.lines, " | ")
}

func (p clientProfile) ipv6Enabled() bool {
	return p.Advanced.IPv6Enabled == nil || *p.Advanced.IPv6Enabled
}

func (p clientProfile) core() string {
	if strings.TrimSpace(p.Core) == "" {
		return "xray"
	}
	return strings.ToLower(strings.TrimSpace(p.Core))
}

func (p clientProfile) validate() error {
	if p.core() == "singbox" {
		_, err := p.singBoxConfig()
		return err
	}
	if p.core() != "xray" {
		return fmt.Errorf("Unsupported Windows VPN runtime %q", p.Core)
	}
	if _, err := p.xrayConfig(1); err != nil {
		return err
	}
	if _, err := p.singBoxBridgeConfig(1); err != nil {
		return err
	}
	return nil
}

func (p clientProfile) xrayConfig(socksPort int) (map[string]any, error) {
	var config map[string]any
	if strings.TrimSpace(p.XrayConfig) != "" {
		var err error
		config, err = parseJSONConfig(p.XrayConfig)
		if err != nil {
			return nil, fmt.Errorf("Invalid Xray JSON: %w", err)
		}
		if len(asArray(config["outbounds"])) == 0 {
			return nil, errors.New("Xray configuration needs at least one outbound")
		}
		if p.EndpointPortOverride != nil && *p.EndpointPortOverride > 0 {
			applyXrayPortOverride(config, *p.EndpointPortOverride)
		}
	} else {
		outbound, err := p.manualXrayOutbound()
		if err != nil {
			return nil, err
		}
		config = map[string]any{
			"log":       map[string]any{"loglevel": "warning"},
			"outbounds": []any{outbound},
		}
	}

	inbounds := asArray(config["inbounds"])
	retained := make([]any, 0, len(inbounds)+1)
	hasSocks := false
	for _, value := range inbounds {
		inbound := asObject(value)
		if inbound == nil {
			continue
		}
		protocol := strings.ToLower(asString(inbound["protocol"]))
		if protocol == "tun" {
			continue
		}
		if protocol == "socks" {
			if hasSocks {
				continue
			}
			hasSocks = true
			inbound["listen"] = "127.0.0.1"
			inbound["port"] = socksPort
			if strings.TrimSpace(asString(inbound["tag"])) == "" {
				inbound["tag"] = "swock-socks"
			}
			settings := ensureObject(inbound, "settings")
			settings["auth"] = "noauth"
			settings["udp"] = true
			delete(settings, "accounts")
		}
		retained = append(retained, inbound)
	}
	if !hasSocks {
		retained = append(retained, map[string]any{
			"tag":      "swock-socks",
			"listen":   "127.0.0.1",
			"port":     socksPort,
			"protocol": "socks",
			"settings": map[string]any{
				"auth": "noauth",
				"udp":  true,
			},
		})
	}
	config["inbounds"] = retained
	return config, nil
}

func (p clientProfile) manualXrayOutbound() (map[string]any, error) {
	protocol := strings.ToLower(strings.TrimSpace(p.Protocol))
	server := firstNonEmpty(p.Server, p.Proxy.Host)
	port := p.Port
	if p.EndpointPortOverride != nil {
		port = *p.EndpointPortOverride
	}
	if port == 0 {
		port = p.Proxy.Port
	}
	if protocol == "xray" {
		return nil, errors.New("This Xray profile needs a complete Xray JSON configuration")
	}
	if protocol == "ssh" {
		return nil, errors.New("SSH tunnel profiles are not supported by this Windows VPN build")
	}
	if server == "" || port < 1 || port > 65535 {
		return nil, errors.New("The VPN profile needs a valid server and port")
	}
	settings := map[string]any{}
	stream := map[string]any{}
	transport, err := p.xrayTransport()
	if err != nil {
		return nil, err
	}
	if transport != "" {
		stream["network"] = transport
	}
	useTLS := p.TLS.Enabled || strings.EqualFold(p.Transport, "websocketTls")
	if useTLS {
		stream["security"] = "tls"
		tlsSettings := map[string]any{}
		serverName := firstNonEmpty(p.TLS.SNI, p.TLS.ServerName)
		if serverName == "" {
			serverName = server
		}
		tlsSettings["serverName"] = serverName
		if p.TLS.AllowInsecureCertificate {
			tlsSettings["allowInsecure"] = true
		}
		if len(p.TLS.ALPN) != 0 {
			tlsSettings["alpn"] = p.TLS.ALPN
		}
		stream["tlsSettings"] = tlsSettings
	} else {
		stream["security"] = "none"
	}
	switch transport {
	case "ws":
		ws := map[string]any{}
		if p.WebSocket.Path != "" {
			ws["path"] = p.WebSocket.Path
		}
		headers := make(map[string]any, len(p.WebSocket.Headers)+1)
		for key, value := range p.WebSocket.Headers {
			headers[key] = value
		}
		if p.WebSocket.Host != "" && !hasHeader(headers, "host") {
			headers["Host"] = p.WebSocket.Host
		}
		if len(headers) != 0 {
			ws["headers"] = headers
		}
		stream["wsSettings"] = ws
	case "httpupgrade":
		settings := map[string]any{}
		if p.WebSocket.Path != "" {
			settings["path"] = p.WebSocket.Path
		}
		if p.WebSocket.Host != "" {
			settings["host"] = p.WebSocket.Host
		}
		stream["httpupgradeSettings"] = settings
	case "http":
		settings := map[string]any{}
		if p.WebSocket.Path != "" {
			settings["path"] = p.WebSocket.Path
		}
		if p.WebSocket.Host != "" {
			settings["host"] = []string{p.WebSocket.Host}
		}
		stream["httpSettings"] = settings
	case "grpc":
		settings := map[string]any{}
		if p.WebSocket.Path != "" {
			settings["serviceName"] = p.WebSocket.Path
		}
		if p.WebSocket.Host != "" {
			settings["authority"] = p.WebSocket.Host
		}
		stream["grpcSettings"] = settings
	case "xhttp":
		settings := map[string]any{"path": p.WebSocket.Path}
		if p.WebSocket.Host != "" {
			settings["host"] = p.WebSocket.Host
		}
		if mode := p.WebSocket.ConnectionOptions["mode"]; mode != "" {
			settings["mode"] = mode
		}
		stream["xhttpSettings"] = settings
	case "quic":
		stream["quicSettings"] = map[string]any{}
	}

	switch protocol {
	case "vless":
		if strings.TrimSpace(p.UUID) == "" {
			return nil, errors.New("VLESS profile is missing its UUID")
		}
		user := map[string]any{"id": p.UUID, "encryption": "none"}
		if p.Flow != "" {
			user["flow"] = p.Flow
		}
		settings["vnext"] = []any{map[string]any{
			"address": server,
			"port":    port,
			"users":   []any{user},
		}}
	case "vmess":
		if strings.TrimSpace(p.UUID) == "" {
			return nil, errors.New("VMess profile is missing its UUID")
		}
		user := map[string]any{
			"id":       p.UUID,
			"alterId":  p.AlterID,
			"security": p.Security,
		}
		if user["security"] == "" {
			user["security"] = "auto"
		}
		settings["vnext"] = []any{map[string]any{
			"address": server,
			"port":    port,
			"users":   []any{user},
		}}
	case "trojan":
		if p.Password == "" {
			return nil, errors.New("Trojan profile is missing its password")
		}
		settings["servers"] = []any{map[string]any{
			"address": server, "port": port, "password": p.Password,
		}}
	case "shadowsocks":
		if p.Password == "" || p.Cipher == "" {
			return nil, errors.New("Shadowsocks profile needs a cipher and password")
		}
		settings["servers"] = []any{map[string]any{
			"address": server, "port": port, "method": p.Cipher, "password": p.Password,
		}}
	case "hysteria2":
		if p.Password == "" {
			return nil, errors.New("Hysteria 2 profile is missing its password")
		}
		settings["address"] = server
		settings["port"] = port
		settings["version"] = 2
		stream["network"] = "hysteria"
		stream["security"] = "tls"
		tlsSettings := asObject(stream["tlsSettings"])
		if tlsSettings == nil {
			tlsSettings = map[string]any{}
		}
		tlsSettings["serverName"] = firstNonEmpty(p.TLS.SNI, p.TLS.ServerName, server)
		stream["tlsSettings"] = tlsSettings
		stream["hysteriaSettings"] = map[string]any{
			"version": 2,
			"auth":    p.Password,
		}
		if strings.EqualFold(p.HysteriaObfs, "salamander") {
			if p.HysteriaObfsPassword == "" {
				return nil, errors.New("Hysteria 2 Salamander profile is missing its obfuscation password")
			}
			stream["finalmask"] = map[string]any{"udp": []any{map[string]any{
				"type":     "salamander",
				"settings": map[string]any{"password": p.HysteriaObfsPassword},
			}}}
		}
	case "socks", "http", "directproxy":
		if server == "" || port < 1 || port > 65535 {
			return nil, errors.New("Proxy profile needs a valid server and port")
		}
		serverConfig := map[string]any{"address": server, "port": port}
		user := p.Proxy.Username
		password := firstNonEmpty(p.Password, p.Proxy.Password)
		if protocol != "directproxy" && user != "" {
			serverConfig["users"] = []any{map[string]any{"user": user, "pass": password}}
		}
		settings["servers"] = []any{serverConfig}
	default:
		return nil, fmt.Errorf("Unsupported Xray profile protocol %q", p.Protocol)
	}
	if protocol == "hysteria2" || protocol == "directproxy" {
		if protocol == "hysteria2" {
			protocol = "hysteria"
		} else {
			protocol = "socks"
		}
	}
	return map[string]any{
		"tag":            "proxy",
		"protocol":       protocol,
		"settings":       settings,
		"streamSettings": stream,
	}, nil
}

func (p clientProfile) xrayTransport() (string, error) {
	switch strings.ToLower(strings.TrimSpace(p.Transport)) {
	case "", "auto":
		if p.WebSocket.Enabled {
			return "ws", nil
		}
		return "", nil
	case "tcp":
		return "tcp", nil
	case "kcp":
		return "kcp", nil
	case "websocket", "websockettls":
		return "ws", nil
	case "httpupgrade":
		return "httpupgrade", nil
	case "http":
		return "http", nil
	case "quic":
		return "quic", nil
	case "grpc":
		return "grpc", nil
	case "xhttp":
		return "xhttp", nil
	default:
		return "", fmt.Errorf("Unsupported Xray transport %q", p.Transport)
	}
}

func (p clientProfile) singBoxBridgeConfig(socksPort int) ([]byte, error) {
	ipv6 := p.ipv6Enabled()
	addresses := []string{tunIPv4Address}
	if ipv6 {
		addresses = append(addresses, tunIPv6Address)
	}
	config := map[string]any{
		"log": map[string]any{"level": "info", "timestamp": true},
		"inbounds": []any{map[string]any{
			"type":           "tun",
			"tag":            "swock-tun",
			"interface_name": singBoxTunName,
			"address":        addresses,
			"auto_route":     false,
			"strict_route":   false,
			"dns_mode":       "disabled",
		}},
		"outbounds": []any{map[string]any{
			"type":        "socks",
			"tag":         "xray",
			"server":      "127.0.0.1",
			"server_port": socksPort,
			"version":     "5",
		}},
		"route": map[string]any{
			"final": "xray",
		},
	}
	return json.MarshalIndent(config, "", "  ")
}

func (p clientProfile) singBoxConfig() ([]byte, error) {
	if strings.TrimSpace(p.XrayConfig) == "" {
		return nil, errors.New("Sing-box profile needs a complete Sing-box JSON configuration")
	}
	config, err := parseJSONConfig(p.XrayConfig)
	if err != nil {
		return nil, fmt.Errorf("Invalid Sing-box JSON: %w", err)
	}
	outbounds := asArray(config["outbounds"])
	if len(outbounds) == 0 {
		return nil, errors.New("Sing-box configuration needs at least one outbound")
	}
	ipv6 := p.ipv6Enabled()
	inbounds := asArray(config["inbounds"])
	retained := make([]any, 0, len(inbounds)+1)
	tunFound := false
	for _, value := range inbounds {
		inbound := asObject(value)
		if inbound == nil {
			continue
		}
		if strings.EqualFold(asString(inbound["type"]), "tun") {
			if tunFound {
				continue
			}
			tunFound = true
			configureTunInbound(inbound, ipv6)
		}
		retained = append(retained, inbound)
	}
	if !tunFound {
		tun := map[string]any{}
		configureTunInbound(tun, ipv6)
		retained = append(retained, tun)
	}
	config["inbounds"] = retained
	route := ensureObject(config, "route")
	if strings.TrimSpace(asString(route["default_interface"])) == "" {
		route["auto_detect_interface"] = true
	} else {
		delete(route, "auto_detect_interface")
	}
	if strings.TrimSpace(asString(route["final"])) == "" {
		if tag := firstProxyTag(outbounds); tag != "" {
			route["final"] = tag
		}
	}
	return json.MarshalIndent(config, "", "  ")
}

func configureTunInbound(inbound map[string]any, ipv6 bool) {
	inbound["type"] = "tun"
	if strings.TrimSpace(asString(inbound["tag"])) == "" {
		inbound["tag"] = "swock-tun"
	}
	inbound["interface_name"] = singBoxTunName
	addresses := []string{tunIPv4Address}
	if ipv6 {
		addresses = append(addresses, tunIPv6Address)
	}
	inbound["address"] = addresses
	inbound["auto_route"] = false
	inbound["strict_route"] = false
	if strings.TrimSpace(asString(inbound["dns_mode"])) == "" {
		inbound["dns_mode"] = "disabled"
	}
}

func (r *run) startClient(manager *Manager, p clientProfile) error {
	var configDir string
	defer func() {
		r.stopProcesses()
		if err := Cleanup(true); err != nil {
			manager.Log("VPN route cleanup: " + err.Error())
		}
		if configDir != "" {
			if err := os.RemoveAll(configDir); err != nil {
				manager.Log("Temporary VPN configuration cleanup: " + err.Error())
			}
		}
	}()

	manager.setState("connecting", "Preparing the Windows VPN tunnel", false)
	if !p.ipv6Enabled() {
		if err := setIPv6Block(true); err != nil {
			return fmt.Errorf("could not enable IPv6 leak protection: %w", err)
		}
	}

	physical, err := defaultRoute()
	if err != nil {
		return err
	}
	var endpointIP net.IP
	if p.core() == "xray" {
		endpoint := p.remoteServer()
		if endpoint != "" {
			endpointIP, err = resolveIPv4(r.ctx, endpoint)
			if err != nil {
				return fmt.Errorf("could not resolve the VPN server %s: %w", endpoint, err)
			}
			if err := addEndpointRoute(endpointIP, physical); err != nil {
				return fmt.Errorf("could not protect the VPN server route: %w", err)
			}
			state := routeState{
				EndpointIP:    endpointIP.String(),
				PhysicalIndex: physical.InterfaceIndex,
				NextHop:       physical.NextHop,
			}
			if err := saveRouteState(state); err != nil {
				_ = removeEndpointRoute(endpointIP, physical)
				return fmt.Errorf("could not save VPN route cleanup state: %w", err)
			}
		}
	}

	configDir, err = os.MkdirTemp("", "swock-vpn-*")
	if err != nil {
		return fmt.Errorf("could not create a temporary VPN configuration directory: %w", err)
	}

	socksPort := 0
	var xrayProcess *supervisedProcess
	if p.core() == "xray" {
		socksPort, err = availableLocalPort()
		if err != nil {
			return fmt.Errorf("could not allocate a local proxy port: %w", err)
		}
		xrayConfig, err := p.xrayConfig(socksPort)
		if err != nil {
			return err
		}
		if endpointIP != nil {
			pinXrayEndpoint(xrayConfig, p.remoteServer(), endpointIP.String())
		}
		xrayConfigPath := filepath.Join(configDir, "xray.json")
		if err := writeConfig(xrayConfigPath, xrayConfig); err != nil {
			return fmt.Errorf("could not write the Xray configuration: %w", err)
		}
		xrayPath, err := adjacentBinary("xray.exe")
		if err != nil {
			return err
		}
		manager.setState("connecting", "Starting Xray-core", false)
		xrayProcess, err = r.startProcess(manager, "Xray", xrayPath, "run", "-c", xrayConfigPath)
		if err != nil {
			return err
		}
		if err := waitForSocks(r.ctx, xrayProcess, socksPort); err != nil {
			return err
		}
	}

	var singBoxConfig []byte
	if p.core() == "singbox" {
		singBoxConfig, err = p.singBoxConfig()
	} else {
		singBoxConfig, err = p.singBoxBridgeConfig(socksPort)
	}
	if err != nil {
		return err
	}
	singBoxConfigPath := filepath.Join(configDir, "sing-box.json")
	if err := os.WriteFile(singBoxConfigPath, singBoxConfig, 0600); err != nil {
		return fmt.Errorf("could not write the Windows tunnel configuration: %w", err)
	}
	singBoxPath, err := adjacentBinary("sing-box.exe")
	if err != nil {
		return err
	}
	check := exec.Command(singBoxPath, "check", "-c", singBoxConfigPath)
	check.Dir = filepath.Dir(singBoxPath)
	if output, err := check.CombinedOutput(); err != nil {
		return fmt.Errorf("Sing-box rejected the Windows tunnel configuration: %s", strings.TrimSpace(string(output)))
	}
	manager.setState("connecting", "Starting the Windows tunnel adapter", false)
	singBoxProcess, err := r.startProcess(manager, "Sing-box", singBoxPath, "run", "-c", singBoxConfigPath)
	if err != nil {
		return err
	}
	if err := waitForTunnelAdapter(r.ctx, singBoxProcess); err != nil {
		return err
	}

	index, err := interfaceIndex(singBoxTunName)
	if err != nil {
		return err
	}
	if _, err := addClientTunnelRoutes(index, endpointIP, physical, p.ipv6Enabled()); err != nil {
		return err
	}
	manager.Log("Windows VPN routes are active")
	manager.setState("connected", "Connected to "+p.Name, true)
	var xrayDone <-chan struct{}
	if xrayProcess != nil {
		xrayDone = xrayProcess.done
	}
	select {
	case <-r.ctx.Done():
		return nil
	case <-singBoxProcess.done:
		return singBoxProcess.failure()
	case <-xrayDone:
		return xrayProcess.failure()
	}
}

func (r *run) startProcess(manager *Manager, name, path string, args ...string) (*supervisedProcess, error) {
	command := exec.CommandContext(r.ctx, path, args...)
	command.Dir = filepath.Dir(path)
	stdout, err := command.StdoutPipe()
	if err != nil {
		return nil, fmt.Errorf("could not read %s output: %w", name, err)
	}
	stderr, err := command.StderrPipe()
	if err != nil {
		return nil, fmt.Errorf("could not read %s errors: %w", name, err)
	}
	if err := command.Start(); err != nil {
		return nil, fmt.Errorf("could not start %s: %w", name, err)
	}
	process := &supervisedProcess{
		name: name,
		cmd:  command,
		done: make(chan struct{}),
	}
	r.mu.Lock()
	r.processes = append(r.processes, process)
	r.mu.Unlock()
	go process.readOutput(manager, stdout)
	go process.readOutput(manager, stderr)
	go func() {
		process.err = command.Wait()
		close(process.done)
	}()
	return process, nil
}

func (p *supervisedProcess) readOutput(manager *Manager, reader io.Reader) {
	scanner := bufio.NewScanner(reader)
	scanner.Buffer(make([]byte, 4096), 1024*1024)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		p.output.add(line)
		manager.Log(p.name + ": " + line)
	}
	if err := scanner.Err(); err != nil {
		manager.Log(p.name + " output error: " + err.Error())
	}
}

func (p *supervisedProcess) failure() error {
	if p.err == nil {
		return fmt.Errorf("%s stopped unexpectedly", p.name)
	}
	if output := p.output.tail(); output != "" {
		return fmt.Errorf("%s stopped: %v (%s)", p.name, p.err, output)
	}
	return fmt.Errorf("%s stopped: %w", p.name, p.err)
}

func waitForSocks(ctx context.Context, process *supervisedProcess, port int) error {
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	timer := time.NewTimer(15 * time.Second)
	defer timer.Stop()
	address := net.JoinHostPort("127.0.0.1", strconv.Itoa(port))
	for {
		connection, err := net.DialTimeout("tcp", address, 150*time.Millisecond)
		if err == nil {
			_ = connection.Close()
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-process.done:
			return process.failure()
		case <-timer.C:
			return fmt.Errorf("Xray did not open its local proxy: %s", process.output.tail())
		case <-ticker.C:
		}
	}
}

func waitForTunnelAdapter(ctx context.Context, process *supervisedProcess) error {
	ticker := time.NewTicker(200 * time.Millisecond)
	defer ticker.Stop()
	timer := time.NewTimer(20 * time.Second)
	defer timer.Stop()
	for {
		if _, err := interfaceIndex(singBoxTunName); err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-process.done:
			return process.failure()
		case <-timer.C:
			return fmt.Errorf("Sing-box did not create the Windows VPN adapter: %s", process.output.tail())
		case <-ticker.C:
		}
	}
}

func (r *run) stopProcesses() {
	r.mu.Lock()
	processes := append([]*supervisedProcess(nil), r.processes...)
	r.mu.Unlock()
	for _, process := range processes {
		if process != nil && process.cmd != nil && process.cmd.Process != nil {
			_ = process.cmd.Process.Kill()
		}
	}
	for _, process := range processes {
		if process == nil {
			continue
		}
		select {
		case <-process.done:
		case <-time.After(5 * time.Second):
		}
	}
}

func adjacentBinary(name string) (string, error) {
	executable, err := os.Executable()
	if err != nil {
		return "", fmt.Errorf("could not locate the Swock VPN runtime: %w", err)
	}
	runtimeDirectory := map[string]string{
		"xray.exe":     filepath.Join("runtime", "xray"),
		"sing-box.exe": filepath.Join("runtime", "sing-box"),
	}[name]
	if runtimeDirectory == "" {
		return "", fmt.Errorf("unknown Windows VPN runtime %s", name)
	}
	path := filepath.Join(filepath.Dir(executable), runtimeDirectory, name)
	if _, err := os.Stat(path); err != nil {
		return "", fmt.Errorf("required Windows VPN runtime %s is missing; reinstall Swock", name)
	}
	return path, nil
}

func writeConfig(path string, value any) error {
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

func availableLocalPort() (int, error) {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer listener.Close()
	_, portText, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		return 0, err
	}
	return strconv.Atoi(portText)
}

func parseJSONConfig(text string) (map[string]any, error) {
	normalized, err := normalizeJSONC(strings.TrimPrefix(strings.TrimSpace(text), "\uFEFF"))
	if err != nil {
		return nil, err
	}
	var decoded any
	if err := json.Unmarshal([]byte(normalized), &decoded); err != nil {
		return nil, err
	}
	if wrapped, ok := decoded.(string); ok {
		normalized, err = normalizeJSONC(wrapped)
		if err != nil {
			return nil, err
		}
		if err := json.Unmarshal([]byte(normalized), &decoded); err != nil {
			return nil, err
		}
	}
	config, ok := decoded.(map[string]any)
	if !ok {
		return nil, errors.New("configuration must be a JSON object")
	}
	return config, nil
}

func normalizeJSONC(source string) (string, error) {
	var commentsRemoved strings.Builder
	quoted, escaped := false, false
	for index := 0; index < len(source); index++ {
		char := source[index]
		if quoted {
			commentsRemoved.WriteByte(char)
			if escaped {
				escaped = false
			} else if char == '\\' {
				escaped = true
			} else if char == '"' {
				quoted = false
			}
			continue
		}
		if char == '"' {
			quoted = true
			commentsRemoved.WriteByte(char)
			continue
		}
		if char == '/' && index+1 < len(source) {
			switch source[index+1] {
			case '/':
				index += 2
				for index < len(source) && source[index] != '\n' {
					index++
				}
				if index < len(source) {
					commentsRemoved.WriteByte('\n')
				}
				continue
			case '*':
				index += 2
				closed := false
				for index+1 < len(source) {
					if source[index] == '*' && source[index+1] == '/' {
						index++
						closed = true
						break
					}
					if source[index] == '\n' {
						commentsRemoved.WriteByte('\n')
					}
					index++
				}
				if !closed {
					return "", errors.New("unterminated JSON comment")
				}
				continue
			}
		}
		commentsRemoved.WriteByte(char)
	}
	if quoted {
		return "", errors.New("unterminated JSON string")
	}
	input := commentsRemoved.String()
	var normalized strings.Builder
	quoted, escaped = false, false
	for index := 0; index < len(input); index++ {
		char := input[index]
		if quoted {
			normalized.WriteByte(char)
			if escaped {
				escaped = false
			} else if char == '\\' {
				escaped = true
			} else if char == '"' {
				quoted = false
			}
			continue
		}
		if char == '"' {
			quoted = true
			normalized.WriteByte(char)
			continue
		}
		if char == ',' {
			next := index + 1
			for next < len(input) && (input[next] == ' ' || input[next] == '\t' || input[next] == '\r' || input[next] == '\n') {
				next++
			}
			if next < len(input) && (input[next] == '}' || input[next] == ']') {
				continue
			}
		}
		normalized.WriteByte(char)
	}
	return normalized.String(), nil
}

func asObject(value any) map[string]any {
	result, _ := value.(map[string]any)
	return result
}

func asArray(value any) []any {
	result, _ := value.([]any)
	return result
}

func asString(value any) string {
	result, _ := value.(string)
	return result
}

func ensureObject(parent map[string]any, key string) map[string]any {
	if existing := asObject(parent[key]); existing != nil {
		return existing
	}
	result := map[string]any{}
	parent[key] = result
	return result
}

func firstProxyTag(outbounds []any) string {
	for _, value := range outbounds {
		outbound := asObject(value)
		if outbound == nil {
			continue
		}
		kind := strings.ToLower(asString(outbound["type"]))
		if kind == "direct" || kind == "block" || kind == "dns" {
			continue
		}
		if tag := strings.TrimSpace(asString(outbound["tag"])); tag != "" {
			return tag
		}
	}
	for _, value := range outbounds {
		if outbound := asObject(value); outbound != nil {
			if tag := strings.TrimSpace(asString(outbound["tag"])); tag != "" {
				return tag
			}
		}
	}
	return ""
}

func hasHeader(headers map[string]any, name string) bool {
	for key := range headers {
		if strings.EqualFold(key, name) {
			return true
		}
	}
	return false
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if trimmed := strings.TrimSpace(value); trimmed != "" {
			return trimmed
		}
	}
	return ""
}

func (p clientProfile) remoteServer() string {
	if server := strings.TrimSpace(p.Server); server != "" {
		return server
	}
	config, err := parseJSONConfig(p.XrayConfig)
	if err != nil {
		return ""
	}
	if p.core() == "singbox" {
		for _, value := range asArray(config["outbounds"]) {
			outbound := asObject(value)
			if outbound == nil {
				continue
			}
			if server := strings.TrimSpace(asString(outbound["server"])); server != "" {
				return server
			}
		}
		return ""
	}
	for _, value := range asArray(config["outbounds"]) {
		outbound := asObject(value)
		if outbound == nil {
			continue
		}
		settings := asObject(outbound["settings"])
		if settings == nil {
			continue
		}
		if servers := asArray(settings["servers"]); len(servers) != 0 {
			if address := strings.TrimSpace(asString(asObject(servers[0])["address"])); address != "" {
				return address
			}
		}
		if next := asArray(settings["vnext"]); len(next) != 0 {
			if address := strings.TrimSpace(asString(asObject(next[0])["address"])); address != "" {
				return address
			}
		}
		if address := strings.TrimSpace(asString(settings["address"])); address != "" {
			return address
		}
	}
	return ""
}

func applyXrayPortOverride(config map[string]any, port int) {
	for _, value := range asArray(config["outbounds"]) {
		outbound := asObject(value)
		if outbound == nil {
			continue
		}
		settings := asObject(outbound["settings"])
		if settings == nil {
			continue
		}
		for _, key := range []string{"servers", "vnext"} {
			servers := asArray(settings[key])
			if len(servers) == 0 {
				continue
			}
			server := asObject(servers[0])
			if server != nil && (asString(server["address"]) != "" || key == "servers") {
				server["port"] = port
				return
			}
		}
		if asString(settings["address"]) != "" {
			settings["port"] = port
			return
		}
	}
}

func pinXrayEndpoint(config map[string]any, host, ip string) {
	host = strings.TrimSuffix(strings.TrimSpace(host), ".")
	if host == "" || ip == "" || net.ParseIP(host) != nil {
		return
	}
	for _, value := range asArray(config["outbounds"]) {
		outbound := asObject(value)
		if outbound == nil {
			continue
		}
		settings := asObject(outbound["settings"])
		if settings == nil {
			continue
		}
		pinned := false
		for _, key := range []string{"servers", "vnext"} {
			for _, serverValue := range asArray(settings[key]) {
				server := asObject(serverValue)
				if server != nil && strings.EqualFold(strings.TrimSuffix(asString(server["address"]), "."), host) {
					server["address"] = ip
					pinned = true
				}
			}
		}
		if strings.EqualFold(strings.TrimSuffix(asString(settings["address"]), "."), host) {
			settings["address"] = ip
			pinned = true
		}
		if !pinned {
			continue
		}

		stream := asObject(outbound["streamSettings"])
		if stream == nil {
			continue
		}
		security := strings.ToLower(asString(stream["security"]))
		if security == "tls" || security == "hysteria" {
			tlsSettings := ensureObject(stream, "tlsSettings")
			if strings.TrimSpace(asString(tlsSettings["serverName"])) == "" {
				tlsSettings["serverName"] = host
			}
		} else if security == "reality" {
			realitySettings := ensureObject(stream, "realitySettings")
			if strings.TrimSpace(asString(realitySettings["serverName"])) == "" {
				realitySettings["serverName"] = host
			}
		}
		if wsSettings := asObject(stream["wsSettings"]); wsSettings != nil {
			headers := ensureObject(wsSettings, "headers")
			if !hasHeader(headers, "host") {
				headers["Host"] = host
			}
		}
		for _, key := range []string{"httpupgradeSettings", "grpcSettings", "xhttpSettings"} {
			settings := asObject(stream[key])
			if settings == nil {
				continue
			}
			hostKey := "host"
			if key == "grpcSettings" {
				hostKey = "authority"
			}
			if strings.TrimSpace(asString(settings[hostKey])) == "" {
				settings[hostKey] = host
			}
		}
		if httpSettings := asObject(stream["httpSettings"]); httpSettings != nil {
			if len(asArray(httpSettings["host"])) == 0 && strings.TrimSpace(asString(httpSettings["host"])) == "" {
				httpSettings["host"] = []string{host}
			}
		}
	}
}
