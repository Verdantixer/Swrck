//go:build windows

package tunnel

import (
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"golang.org/x/sys/windows"
	"golang.zx2c4.com/wintun"
)

const adapterName = "Swock VPN"
const adapterType = "Wintun"

type packetSession interface {
	ReceivePacket() ([]byte, error)
	ReleaseReceivePacket([]byte)
	AllocateSendPacket(int) ([]byte, error)
	SendPacket([]byte)
	ReadWaitEvent() windows.Handle
	End()
}

type routeState struct {
	InterfaceIndex uint32 `json:"interfaceIndex"`
	EndpointIP     string `json:"endpointIP"`
	PhysicalIndex  uint32 `json:"physicalIndex"`
	NextHop        string `json:"nextHop"`
}

type physicalRoute struct {
	InterfaceIndex uint32
	NextHop        string
}

func createTunnelAdapter(address string) (*wintun.Adapter, packetSession, uint32, error) {
	adapter, err := wintun.CreateAdapter(adapterName, adapterType, nil)
	if err != nil {
		return nil, nil, 0, fmt.Errorf("could not create the Windows VPN adapter (run Swock as administrator): %w", err)
	}
	session, err := adapter.StartSession(0x400000)
	if err != nil {
		_ = adapter.Close()
		return nil, nil, 0, fmt.Errorf("could not start the Windows VPN adapter: %w", err)
	}
	index, err := interfaceIndex(adapterName)
	if err != nil {
		session.End()
		_ = adapter.Close()
		return nil, nil, 0, err
	}
	return adapter, session, index, nil
}

func deleteTunnelAdapter(adapter *wintun.Adapter) error {
	if adapter == nil {
		return nil
	}
	return adapter.Close()
}

func setTunnelAddress(index uint32, address string) error {
	if err := netsh("interface", "ipv4", "set", "address", "name="+fmt.Sprint(index), "source=static", "address="+address, "mask=255.255.255.255", "gateway=none", "store=active"); err != nil {
		return fmt.Errorf("could not assign the VPN address: %w", err)
	}
	return nil
}

func defaultRoute() (physicalRoute, error) {
	const script = `$r = Get-NetRoute -AddressFamily IPv4 -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1; [pscustomobject]@{InterfaceIndex=[uint32]$r.InterfaceIndex; NextHop=[string]$r.NextHop} | ConvertTo-Json -Compress`
	output, err := powershell(script)
	if err != nil {
		return physicalRoute{}, fmt.Errorf("could not read the active internet route: %w", err)
	}
	var route physicalRoute
	if err := json.Unmarshal(output, &route); err != nil || route.InterfaceIndex == 0 {
		return physicalRoute{}, errors.New("could not identify the active internet interface")
	}
	return route, nil
}

func addEndpointRoute(endpoint net.IP, route physicalRoute) error {
	return netsh("interface", "ipv4", "add", "route", "prefix="+endpoint.String()+"/32", "interface="+fmt.Sprint(route.InterfaceIndex), "nexthop="+route.NextHop, "metric=1", "store=active")
}

func removeEndpointRoute(endpoint net.IP, route physicalRoute) error {
	return netsh("interface", "ipv4", "delete", "route", "prefix="+endpoint.String()+"/32", "interface="+fmt.Sprint(route.InterfaceIndex), "nexthop="+route.NextHop, "store=active")
}

func addTunnelRoutes(index uint32, endpoint net.IP, physical physicalRoute, address string) (routeState, error) {
	state := routeState{InterfaceIndex: index, EndpointIP: endpoint.String(), PhysicalIndex: physical.InterfaceIndex, NextHop: physical.NextHop}
	if err := netsh("interface", "ipv4", "add", "route", "prefix=0.0.0.0/1", "interface="+fmt.Sprint(index), "nexthop=0.0.0.0", "metric=1", "store=active"); err != nil {
		return state, fmt.Errorf("could not add the first VPN route: %w", err)
	}
	if err := netsh("interface", "ipv4", "add", "route", "prefix=128.0.0.0/1", "interface="+fmt.Sprint(index), "nexthop=0.0.0.0", "metric=1", "store=active"); err != nil {
		_ = removeTunnelRoutes(state)
		return state, fmt.Errorf("could not add the second VPN route: %w", err)
	}
	if err := setIPv6Block(true); err != nil {
		_ = removeTunnelRoutes(state)
		return state, fmt.Errorf("could not enable IPv6 leak protection: %w", err)
	}
	if err := saveRouteState(state); err != nil {
		_ = removeTunnelRoutes(state)
		return state, fmt.Errorf("could not save VPN cleanup state: %w", err)
	}
	_ = address
	return state, nil
}

func removeTunnelRoutes(state routeState) error {
	var errs []string
	for _, prefix := range []string{"0.0.0.0/1", "128.0.0.0/1"} {
		if err := netsh("interface", "ipv4", "delete", "route", "prefix="+prefix, "interface="+fmt.Sprint(state.InterfaceIndex), "nexthop=0.0.0.0", "store=active"); err != nil {
			errs = append(errs, err.Error())
		}
	}
	if state.EndpointIP != "" && state.PhysicalIndex != 0 {
		if ip := net.ParseIP(state.EndpointIP); ip != nil {
			_ = removeEndpointRoute(ip, physicalRoute{InterfaceIndex: state.PhysicalIndex, NextHop: state.NextHop})
		}
	}
	_ = setIPv6Block(false)
	_ = os.Remove(routeStatePath())
	if len(errs) != 0 {
		return errors.New(strings.Join(errs, "; "))
	}
	return nil
}

func Cleanup(removeAdapter bool) error {
	var state routeState
	if data, err := os.ReadFile(routeStatePath()); err == nil {
		_ = json.Unmarshal(data, &state)
	}
	if state.InterfaceIndex != 0 {
		_ = removeTunnelRoutes(state)
	} else {
		// Recover split routes left behind if the app was terminated unexpectedly.
		if index, err := interfaceIndex(adapterName); err == nil {
			_ = netsh("interface", "ipv4", "delete", "route", "prefix=0.0.0.0/1", "interface="+fmt.Sprint(index), "nexthop=0.0.0.0", "store=active")
			_ = netsh("interface", "ipv4", "delete", "route", "prefix=128.0.0.0/1", "interface="+fmt.Sprint(index), "nexthop=0.0.0.0", "store=active")
		}
		_ = setIPv6Block(false)
	}
	// Remove an orphaned Swock adapter after unclean shutdowns. It is safe to
	// do this on service startup too: the control pipe lock guarantees there is
	// no other Swock core process using this adapter.
	// Only remove a device on uninstall or when persisted Swock route state
	// proves an unclean VPN session may have left it behind.
	if removeAdapter || state.InterfaceIndex != 0 {
		_, _ = powershell(`Get-PnpDevice -Class Net -ErrorAction SilentlyContinue | Where-Object { $_.FriendlyName -eq 'Swock VPN' } | ForEach-Object { pnputil.exe /remove-device $_.InstanceId | Out-Null }`)
	}
	return nil
}

func interfaceIndex(name string) (uint32, error) {
	script := fmt.Sprintf(`$a = Get-NetAdapter -Name '%s' -ErrorAction Stop; [uint32]$a.ifIndex`, strings.ReplaceAll(name, "'", "''"))
	output, err := powershell(script)
	if err != nil {
		return 0, fmt.Errorf("could not find the Swock VPN adapter: %w", err)
	}
	var index uint32
	if _, err := fmt.Sscan(strings.TrimSpace(string(output)), &index); err != nil || index == 0 {
		return 0, errors.New("could not read the Windows VPN adapter index")
	}
	return index, nil
}

func setIPv6Block(enabled bool) error {
	if enabled {
		_, err := powershell(`if (-not (Get-NetFirewallRule -DisplayName 'Swock VPN IPv6 leak protection' -ErrorAction SilentlyContinue)) { New-NetFirewallRule -DisplayName 'Swock VPN IPv6 leak protection' -Direction Outbound -Action Block -RemoteAddress '::/0' -Profile Any | Out-Null }`)
		return err
	}
	_, err := powershell(`Get-NetFirewallRule -DisplayName 'Swock VPN IPv6 leak protection' -ErrorAction SilentlyContinue | Remove-NetFirewallRule`)
	return err
}

func saveRouteState(state routeState) error {
	path := routeStatePath()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.Marshal(state)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0600)
}

func routeStatePath() string {
	return filepath.Join(os.Getenv("ProgramData"), "Swock", "route-state.json")
}

func netsh(args ...string) error {
	command := exec.Command("netsh.exe", args...)
	output, err := command.CombinedOutput()
	if err != nil {
		return fmt.Errorf("%s: %s", err, strings.TrimSpace(string(output)))
	}
	return nil
}

func powershell(script string) ([]byte, error) {
	command := exec.Command("powershell.exe", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", "$ErrorActionPreference='Stop'; "+script)
	output, err := command.CombinedOutput()
	if err != nil {
		return output, fmt.Errorf("%s: %s", err, strings.TrimSpace(string(output)))
	}
	return output, nil
}

var _ packetSession = (*wintun.Session)(nil)
