//go:build windows

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"

	"github.com/Microsoft/go-winio"
	"github.com/Verdantixer/Swrck/windows/core/internal/tunnel"
)

const pipeName = `\\.\pipe\SwockVpnControl`

func main() {
	if len(os.Args) < 2 {
		fail("usage: swock_core.exe serve|control|cleanup")
	}
	switch os.Args[1] {
	case "serve":
		serve()
	case "control":
		control()
	case "cleanup":
		if err := tunnel.Cleanup(true); err != nil {
			fail(err.Error())
		}
	case "--version":
		fmt.Println("Swock Windows VPN core 1.0.0")
	default:
		fail("unknown command")
	}
}

func serve() {
	if len(os.Args) != 3 {
		fail("serve requires the Flutter process ID")
	}
	parentPID, err := strconv.ParseUint(os.Args[2], 10, 32)
	if err != nil || parentPID == 0 {
		fail("invalid parent process ID")
	}
	manager := tunnel.NewManager()
	parentDone, err := manager.WatchParent(uint32(parentPID))
	if err != nil {
		fail(err.Error())
	}
	config := &winio.PipeConfig{SecurityDescriptor: "D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;OW)"}
	listener, err := winio.ListenPipe(pipeName, config)
	if err != nil {
		fail("Cannot start the local VPN control service: " + err.Error())
	}
	defer listener.Close()
	if err := tunnel.Cleanup(false); err != nil {
		manager.Log("Stale route cleanup: " + err.Error())
	}
	go func() {
		<-parentDone
		_ = listener.Close()
	}()
	manager.Log("Swock Windows VPN service started")

	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, io.EOF) {
				return
			}
			manager.Log("Control pipe stopped: " + err.Error())
			return
		}
		go handleControl(conn, manager)
	}
}

func handleControl(conn io.ReadWriteCloser, manager *tunnel.Manager) {
	defer conn.Close()
	var request struct {
		Command string          `json:"command"`
		Profile json.RawMessage `json:"profile"`
	}
	if err := json.NewDecoder(bufio.NewReader(conn)).Decode(&request); err != nil {
		writeJSON(conn, map[string]any{"ok": false, "error": "Invalid control request"})
		return
	}
	var response any
	switch request.Command {
	case "connect":
		if len(request.Profile) == 0 || string(request.Profile) == "null" {
			response = map[string]any{"ok": false, "error": "A VPN profile is required"}
			break
		}
		profileJSON := request.Profile
		if len(profileJSON) > 0 && profileJSON[0] == '"' {
			var encoded string
			if err := json.Unmarshal(profileJSON, &encoded); err != nil {
				response = map[string]any{"ok": false, "error": "Invalid VPN profile"}
				break
			}
			profileJSON = json.RawMessage(encoded)
		}
		if err := manager.Connect(profileJSON); err != nil {
			response = map[string]any{"ok": false, "error": err.Error()}
		} else {
			response = map[string]any{"ok": true}
		}
	case "disconnect":
		manager.Disconnect()
		response = map[string]any{"ok": true}
	case "status":
		response = map[string]any{"ok": true, "value": manager.Status()}
	case "statistics":
		response = map[string]any{"ok": true, "value": manager.Statistics()}
	case "drainLogs":
		response = map[string]any{"ok": true, "value": manager.DrainLogs()}
	case "clearLogs":
		manager.ClearLogs()
		response = map[string]any{"ok": true}
	default:
		response = map[string]any{"ok": false, "error": "Unsupported VPN command"}
	}
	writeJSON(conn, response)
}

func control() {
	request, err := io.ReadAll(io.LimitReader(os.Stdin, 1<<20))
	if err != nil || len(request) == 0 {
		fail("missing control request")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	conn, err := winio.DialPipeContext(ctx, pipeName)
	if err != nil {
		fail("VPN service is not running")
	}
	defer conn.Close()
	if _, err := conn.Write(append(request, '\n')); err != nil {
		fail("Cannot send VPN command")
	}
	response, err := io.ReadAll(io.LimitReader(conn, 1<<20))
	if err != nil || len(response) == 0 {
		fail("VPN service did not respond")
	}
	_, _ = os.Stdout.Write(response)
}

func writeJSON(writer io.Writer, value any) {
	_ = json.NewEncoder(writer).Encode(value)
}

func fail(message string) {
	_, _ = fmt.Fprintln(os.Stderr, message)
	os.Exit(1)
}
