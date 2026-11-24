//go:build windows

package tunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"sync"
	"time"

	"golang.org/x/sys/windows"
)

type Manager struct {
	mu         sync.Mutex
	active     *run
	state      string
	connected  bool
	message    string
	logs       []map[string]any
	uploaded   int64
	downloaded int64
	startedAt  time.Time
}

type run struct {
	ctx    context.Context
	cancel context.CancelFunc
	done   chan struct{}
	mu     sync.Mutex
	conn   closeable
}

type closeable interface{ Close() error }

func NewManager() *Manager {
	return &Manager{state: "disconnected", message: "Disconnected"}
}

func (m *Manager) WatchParent(pid uint32) (<-chan struct{}, error) {
	process, err := windows.OpenProcess(windows.SYNCHRONIZE, false, pid)
	if err != nil {
		return nil, fmt.Errorf("cannot monitor the Swock app process: %w", err)
	}
	done := make(chan struct{})
	go func() {
		defer windows.CloseHandle(process)
		_, _ = windows.WaitForSingleObject(process, windows.INFINITE)
		m.Log("Swock app closed; stopping the tunnel")
		m.Disconnect()
		close(done)
	}()
	return done, nil
}

func (m *Manager) Connect(profileJSON json.RawMessage) error {
	var profile Profile
	if err := json.Unmarshal(profileJSON, &profile); err != nil {
		return errors.New("Could not read the VPN profile")
	}
	if err := profile.Validate(); err != nil {
		return err
	}
	m.Disconnect()
	ctx, cancel := context.WithCancel(context.Background())
	active := &run{ctx: ctx, cancel: cancel, done: make(chan struct{})}
	m.mu.Lock()
	m.active = active
	m.uploaded, m.downloaded = 0, 0
	m.startedAt = time.Time{}
	m.state, m.connected, m.message = "connecting", false, "Preparing the Windows VPN tunnel"
	m.mu.Unlock()
	m.Log("Starting Windows tunnel")
	go func() {
		defer close(active.done)
		err := active.start(m, profile)
		active.stop()
		m.mu.Lock()
		if m.active == active {
			m.active = nil
			m.connected = false
			if ctx.Err() != nil {
				m.state, m.message = "disconnected", "Disconnected"
			} else if err != nil {
				m.state, m.message = "error", err.Error()
			} else {
				m.state, m.message = "disconnected", "Disconnected"
			}
		}
		m.mu.Unlock()
		if err != nil && ctx.Err() == nil {
			m.Log("VPN stopped: " + err.Error())
		}
	}()
	return nil
}

func (m *Manager) Disconnect() {
	m.mu.Lock()
	active := m.active
	if active == nil {
		m.state, m.connected, m.message = "disconnected", false, "Disconnected"
		m.mu.Unlock()
		_ = Cleanup(false)
		return
	}
	active.cancel()
	active.mu.Lock()
	if active.conn != nil {
		_ = active.conn.Close()
	}
	active.mu.Unlock()
	m.mu.Unlock()
	select {
	case <-active.done:
	case <-time.After(10 * time.Second):
		m.Log("Tunnel cleanup is taking longer than expected")
	}
}

func (m *Manager) setState(state, message string, connected bool) {
	m.mu.Lock()
	m.state, m.message, m.connected = state, message, connected
	if connected && m.startedAt.IsZero() {
		m.startedAt = time.Now()
	}
	m.mu.Unlock()
	m.Log(message)
}

func (m *Manager) addStats(uploaded, downloaded int) {
	m.mu.Lock()
	m.uploaded += int64(uploaded)
	m.downloaded += int64(downloaded)
	m.mu.Unlock()
}

func (m *Manager) Status() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	return map[string]any{"state": m.state, "connected": m.connected, "message": m.message}
}

func (m *Manager) Statistics() map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	duration := int64(0)
	if m.connected && !m.startedAt.IsZero() {
		duration = time.Since(m.startedAt).Milliseconds()
	}
	return map[string]any{"uploadBytes": m.uploaded, "downloadBytes": m.downloaded, "durationMs": duration}
}

func (m *Manager) Log(message string) {
	m.mu.Lock()
	m.logs = append(m.logs, map[string]any{"timestamp": time.Now().UnixMilli(), "message": message})
	if len(m.logs) > 500 {
		m.logs = append([]map[string]any(nil), m.logs[len(m.logs)-500:]...)
	}
	m.mu.Unlock()
}

func (m *Manager) DrainLogs() []map[string]any {
	m.mu.Lock()
	defer m.mu.Unlock()
	logs := m.logs
	m.logs = nil
	return logs
}

func (m *Manager) ClearLogs() {
	m.mu.Lock()
	m.logs = nil
	m.mu.Unlock()
}
