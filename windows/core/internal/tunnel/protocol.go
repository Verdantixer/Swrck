//go:build windows

package tunnel

import (
	"context"
	cryptorand "crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"math/rand/v2"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/gorilla/websocket"
	"golang.org/x/crypto/chacha20poly1305"
	"golang.org/x/crypto/curve25519"
	"golang.org/x/sys/windows"
)

type Profile struct {
	Name             string          `json:"name"`
	Server           string          `json:"server"`
	Port             int             `json:"port"`
	Protocol         string          `json:"protocol"`
	Transport        string          `json:"transport"`
	ServerPublicKey  string          `json:"serverPublicKey"`
	ClientPrivateKey string          `json:"clientPrivateKey"`
	TunnelAddress    string          `json:"tunnelAddress"`
	TLS              tlsProfile      `json:"tls"`
	WebSocket        websocketProfile `json:"webSocket"`
	Advanced         advancedProfile `json:"advanced"`
}

type tlsProfile struct {
	Enabled                 bool   `json:"enabled"`
	SNI                     string `json:"sni"`
	ServerName              string `json:"serverName"`
	AllowInsecureCertificate bool  `json:"allowInsecureCertificate"`
}

type websocketProfile struct {
	Enabled bool              `json:"enabled"`
	Path    string            `json:"path"`
	Host    string            `json:"host"`
	Headers map[string]string `json:"headers"`
}

type advancedProfile struct {
	StealthObfuscation bool `json:"stealthObfuscation"`
}

func (p Profile) Validate() error {
	if strings.ToLower(p.Protocol) != "swock" && p.Protocol != "" {
		return errors.New("The Windows client currently supports Swock SWK2 profiles only")
	}
	if strings.TrimSpace(p.Server) == "" || p.Port < 1 || p.Port > 65535 {
		return errors.New("The VPN profile needs a valid server and port")
	}
	if len(p.ServerPublicKey) != 64 || len(p.ClientPrivateKey) != 64 {
		return errors.New("The VPN profile must include its 32-byte client key and pinned server key")
	}
	if _, err := hex.DecodeString(p.ServerPublicKey); err != nil {
		return errors.New("The VPN profile server key is invalid")
	}
	if _, err := hex.DecodeString(p.ClientPrivateKey); err != nil {
		return errors.New("The VPN profile client key is invalid")
	}
	parts := strings.Split(p.TunnelAddress, ".")
	if len(parts) != 4 || !strings.HasPrefix(p.TunnelAddress, "10.8.0.") {
		return errors.New("This profile is not a current SWK2 profile. Reissue it from the Swock panel")
	}
	last, err := strconv.Atoi(parts[3])
	if err != nil || last < 2 || last > 254 {
		return errors.New("The profile tunnel address must be between 10.8.0.2 and 10.8.0.254")
	}
	return nil
}

func (r *run) start(manager *Manager, p Profile) error {
	setStatus := func(state, message string, connected bool) {
		manager.setState(state, message, connected)
	}
	setStatus("connecting", "Resolving the Swock server", false)
	endpointIP, err := resolveIPv4(r.ctx, p.Server)
	if err != nil {
		return err
	}
	physical, err := defaultRoute()
	if err != nil {
		return err
	}
	if err := addEndpointRoute(endpointIP, physical); err != nil {
		return fmt.Errorf("could not protect the Swock server route: %w", err)
	}
	adapter, session, iface, err := createTunnelAdapter(p.TunnelAddress)
	if err != nil {
		_ = removeEndpointRoute(endpointIP, physical)
		return err
	}
	var conn net.Conn
	var routeState routeState
	cleanup := func() {
		if conn != nil {
			_ = conn.Close()
		}
		session.End()
		if routeState.InterfaceIndex != 0 {
			_ = removeTunnelRoutes(routeState)
		}
		_ = removeEndpointRoute(endpointIP, physical)
		_ = deleteTunnelAdapter(adapter)
	}
	defer cleanup()
	if err := setTunnelAddress(iface, p.TunnelAddress); err != nil {
		return err
	}
	setStatus("connecting", fmt.Sprintf("Connecting to %s", p.Server), false)
	conn, err = dialTransport(r.ctx, p, endpointIP)
	if err != nil {
		return fmt.Errorf("could not connect to the Swock server: %w", err)
	}
	r.setConn(conn)
	defer r.setConn(nil)
	var c2sKey, s2cKey [32]byte
	if err := performHandshake(conn, p, &c2sKey, &s2cKey); err != nil {
		return fmt.Errorf("Swock authentication failed: %w", err)
	}
	setStatus("connecting", "Configuring Windows network routes", false)
	routeState, err = addTunnelRoutes(iface, endpointIP, physical, p.TunnelAddress)
	if err != nil {
		return err
	}
	setStatus("connected", fmt.Sprintf("Connected to %s", p.Name), true)
	errCh := make(chan error, 2)
	var tx, rx atomic.Int64
	tx.Store(1)
	rx.Store(1)
	var writeMu sync.Mutex
	go func() { errCh <- r.readTun(manager, session, conn, p, c2sKey, &writeMu, &tx) }()
	go func() { errCh <- r.readServer(manager, session, conn, p, s2cKey, &rx) }()
	select {
	case <-r.ctx.Done():
		return nil
	case err := <-errCh:
		if r.ctx.Err() != nil {
			return nil
		}
		return fmt.Errorf("VPN tunnel stopped: %w", err)
	}
}

func (r *run) setConn(conn net.Conn) {
	r.mu.Lock()
	r.conn = conn
	r.mu.Unlock()
}

func (r *run) stop() {
	r.mu.Lock()
	if r.conn != nil {
		_ = r.conn.Close()
	}
	r.mu.Unlock()
}

func (r *run) readTun(manager *Manager, session packetSession, conn net.Conn, p Profile, key [32]byte, writeMu *sync.Mutex, counter *atomic.Int64) error {
	for {
		packet, err := session.ReceivePacket()
		if err != nil {
			if errors.Is(err, windowsErrNoPackets()) {
				_, _ = windowsWaitForObject(session.ReadWaitEvent())
				continue
			}
			return err
		}
		payload := packet
		if p.Advanced.StealthObfuscation && len(packet) < 512 {
			padLen := 4 + rand.IntN(29)
			padded := make([]byte, 2+padLen+len(packet))
			padded[0], padded[1] = 0xFE, byte(padLen)
			if _, err := cryptorand.Read(padded[2 : 2+padLen]); err != nil {
				session.ReleaseReceivePacket(packet)
				return err
			}
			copy(padded[2+padLen:], packet)
			payload = padded
		}
		nonce := packetNonce(counter.Load())
		counter.Add(1)
		frame, err := encryptFrame(payload, key, nonce)
		session.ReleaseReceivePacket(packet)
		if err != nil { return err }
		writeMu.Lock()
		_, err = conn.Write(frame)
		writeMu.Unlock()
		if err != nil {
			return err
		}
		manager.addStats(len(packet), 0)
	}
}

func (r *run) readServer(manager *Manager, session packetSession, conn net.Conn, p Profile, key [32]byte, counter *atomic.Int64) error {
	for {
		var size [4]byte
		if _, err := io.ReadFull(conn, size[:]); err != nil {
			return err
		}
		length := binary.BigEndian.Uint32(size[:])
		if length < 17 || length > 65535+16 {
			return errors.New("invalid encrypted packet frame length")
		}
		frame := make([]byte, length)
		if _, err := io.ReadFull(conn, frame); err != nil {
			return err
		}
		packet, err := decryptFrame(frame, key, packetNonce(counter.Load()))
		if err != nil {
			return errors.New("server packet authentication failed")
		}
		counter.Add(1)
		if p.Advanced.StealthObfuscation && len(packet) >= 2 && packet[0] == 0xFE {
			padding := int(packet[1])
			if 2+padding <= len(packet) {
				packet = packet[2+padding:]
			}
		}
		out, err := session.AllocateSendPacket(len(packet))
		if err != nil { return err }
		copy(out, packet)
		session.SendPacket(out)
		manager.addStats(0, len(packet))
	}
}

func dialTransport(ctx context.Context, p Profile, endpoint net.IP) (net.Conn, error) {
	server := net.JoinHostPort(endpoint.String(), strconv.Itoa(p.Port))
	tlsEnabled := p.TLS.Enabled || strings.EqualFold(p.Transport, "websocketTls")
	wsEnabled := p.WebSocket.Enabled || strings.EqualFold(p.Transport, "websocket") || strings.EqualFold(p.Transport, "websocketTls")
	tlsName := strings.TrimSpace(p.TLS.ServerName)
	if tlsName == "" {
		tlsName = strings.TrimSpace(p.TLS.SNI)
	}
	if tlsName == "" {
		tlsName = p.Server
	}
	if !wsEnabled {
		dialer := &net.Dialer{Timeout: 7 * time.Second, KeepAlive: 30 * time.Second}
		conn, err := dialer.DialContext(ctx, "tcp", server)
		if err != nil {
			return nil, err
		}
		if !tlsEnabled {
			return conn, nil
		}
		tlsConn := tls.Client(conn, tlsConfig(tlsName, p.TLS.AllowInsecureCertificate))
		_ = tlsConn.SetDeadline(time.Now().Add(7 * time.Second))
		if err := tlsConn.HandshakeContext(ctx); err != nil {
			_ = conn.Close()
			return nil, err
		}
		_ = tlsConn.SetDeadline(time.Time{})
		return tlsConn, nil
	}
	path := p.WebSocket.Path
	if path == "" {
		path = "/"
	}
	if !strings.HasPrefix(path, "/") {
		return nil, errors.New("WebSocket path must start with /")
	}
	scheme := "ws"
	if tlsEnabled {
		scheme = "wss"
	}
	url := fmt.Sprintf("%s://%s:%d%s", scheme, p.Server, p.Port, path)
	if strings.Contains(p.Server, ":") && !strings.HasPrefix(p.Server, "[") {
		url = fmt.Sprintf("%s://[%s]:%d%s", scheme, p.Server, p.Port, path)
	}
	header := http.Header{}
	for key, value := range p.WebSocket.Headers {
		header.Set(key, value)
	}
	dialer := websocket.Dialer{HandshakeTimeout: 10 * time.Second, Proxy: http.ProxyFromEnvironment}
	if tlsEnabled {
		dialer.TLSClientConfig = tlsConfig(tlsName, p.TLS.AllowInsecureCertificate)
	}
	if host := strings.TrimSpace(p.WebSocket.Host); host != "" {
		header.Set("Host", host)
	}
	ws, _, err := dialer.DialContext(ctx, url, header)
	if err != nil {
		return nil, err
	}
	return newWebSocketStreamConn(ctx, ws), nil
}

func tlsConfig(serverName string, allowNameMismatch bool) *tls.Config {
	config := &tls.Config{MinVersion: tls.VersionTLS12, ServerName: serverName}
	if !allowNameMismatch {
		return config
	}
	config.InsecureSkipVerify = true // The chain is still verified in VerifyConnection below.
	config.VerifyConnection = func(state tls.ConnectionState) error {
		if len(state.PeerCertificates) == 0 {
			return errors.New("TLS peer did not present a certificate")
		}
		roots, err := x509.SystemCertPool()
		if err != nil || roots == nil {
			roots = x509.NewCertPool()
		}
		intermediates := x509.NewCertPool()
		for _, cert := range state.PeerCertificates[1:] {
			intermediates.AddCert(cert)
		}
		_, err = state.PeerCertificates[0].Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates, KeyUsages: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}})
		return err
	}
	return config
}

func performHandshake(conn net.Conn, p Profile, c2sKey, s2cKey *[32]byte) error {
	privateKey, _ := hex.DecodeString(p.ClientPrivateKey)
	serverKey, _ := hex.DecodeString(p.ServerPublicKey)
	clientPublic, err := curve25519.X25519(privateKey, curve25519.Basepoint)
	if err != nil {
		return err
	}
	if _, err := conn.Write(append([]byte("SWK2"), clientPublic...)); err != nil {
		return err
	}
	_ = conn.SetReadDeadline(time.Now().Add(7 * time.Second))
	var responseMagic [4]byte
	if _, err := io.ReadFull(conn, responseMagic[:]); err != nil {
		return err
	}
	if string(responseMagic[:]) != "SWK2" {
		return errors.New("server rejected SWK2; reissue the profile if it still uses SWK1")
	}
	receivedKey := make([]byte, 32)
	if _, err := io.ReadFull(conn, receivedKey); err != nil {
		return err
	}
	if !equalBytes(receivedKey, serverKey) {
		return errors.New("server key does not match the pinned profile key")
	}
	sharedSecret, err := curve25519.X25519(privateKey, receivedKey)
	if err != nil {
		return err
	}
	var address [4]byte
	if _, err := io.ReadFull(conn, address[:]); err != nil {
		return err
	}
	expected := net.ParseIP(p.TunnelAddress).To4()
	if expected == nil || !equalBytes(address[:], expected) {
		return errors.New("server assigned an address different from the profile")
	}
	salt := make([]byte, 32)
	if _, err := io.ReadFull(conn, salt); err != nil {
		return err
	}
	transcriptInput := append(append(append(append([]byte{}, sharedSecret...), clientPublic...), receivedKey...), salt...)
	transcript := sha256.Sum256(transcriptInput)
	c2s := sha256.Sum256(append(append([]byte{}, transcript[:]...), []byte("swock-v2-client-to-server")...))
	s2c := sha256.Sum256(append(append([]byte{}, transcript[:]...), []byte("swock-v2-server-to-client")...))
	copy(c2sKey[:], c2s[:])
	copy(s2cKey[:], s2c[:])
	proof, err := encryptFrame([]byte("SWK2 client key confirmation"), *c2sKey, packetNonce(0))
	if err != nil {
		return err
	}
	if _, err := conn.Write(proof); err != nil {
		return err
	}
	var proofLength [4]byte
	if _, err := io.ReadFull(conn, proofLength[:]); err != nil {
		return err
	}
	length := binary.BigEndian.Uint32(proofLength[:])
	if length < 17 || length > 144 {
		return errors.New("invalid server key confirmation length")
	}
	serverProof := make([]byte, length)
	if _, err := io.ReadFull(conn, serverProof); err != nil {
		return err
	}
	plain, err := chacha20poly1305.New(s2cKey[:])
	if err != nil {
		return err
	}
	verified, err := plain.Open(nil, packetNonce(0), serverProof, nil)
	if err != nil || string(verified) != "SWK2 server key confirmation" {
		return errors.New("server did not prove possession of its private key")
	}
	_ = conn.SetReadDeadline(time.Time{})
	return nil
}

func windowsErrNoPackets() error { return windows.ERROR_NO_MORE_ITEMS }

func windowsWaitForObject(handle windows.Handle) (uint32, error) {
	return windows.WaitForSingleObject(handle, windows.INFINITE)
}

func encryptFrame(packet []byte, key [32]byte, nonce []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key[:])
	if err != nil {
		return nil, err
	}
	sealed := aead.Seal(nil, nonce, packet, nil)
	frame := make([]byte, 4+len(sealed))
	binary.BigEndian.PutUint32(frame[:4], uint32(len(sealed)))
	copy(frame[4:], sealed)
	return frame, nil
}

func decryptFrame(frame []byte, key [32]byte, nonce []byte) ([]byte, error) {
	aead, err := chacha20poly1305.New(key[:])
	if err != nil {
		return nil, err
	}
	return aead.Open(nil, nonce, frame, nil)
}

func packetNonce(counter int64) []byte {
	nonce := make([]byte, chacha20poly1305.NonceSize)
	binary.BigEndian.PutUint64(nonce[4:], uint64(counter))
	return nonce
}

func resolveIPv4(ctx context.Context, host string) (net.IP, error) {
	if ip := net.ParseIP(host).To4(); ip != nil {
		return ip, nil
	}
	ips, err := net.DefaultResolver.LookupIP(ctx, "ip4", host)
	if err != nil || len(ips) == 0 {
		return nil, fmt.Errorf("could not resolve an IPv4 address for %s", host)
	}
	return ips[0].To4(), nil
}

func equalBytes(a, b []byte) bool {
	if len(a) != len(b) {
		return false
	}
	var diff byte
	for i := range a {
		diff |= a[i] ^ b[i]
	}
	return diff == 0
}
