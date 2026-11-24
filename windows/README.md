# Swock VPN for Windows

The Windows client supports:

- Xray profiles using the bundled Xray-core runtime, including imported Xray JSON and the app's manual VLESS, VMess, Trojan, Shadowsocks, Hysteria 2, SOCKS, and HTTP profiles.
- Native Sing-box JSON profiles using the bundled Sing-box runtime.
- Legacy SWK2 profiles using the existing native tunnel.

Xray profiles use a loopback SOCKS bridge into a Sing-box Wintun TUN adapter. Native Sing-box profiles retain their core configuration and receive a Windows TUN inbound. The app's IPv6 setting controls whether IPv6 is routed through the VPN or blocked while connected. SSH profiles are not supported on Windows yet.

The Xray and Sing-box runtimes are pinned to Xray-core `v26.11.9` and Sing-box `v1.14.4`; the installer includes their accompanying data files, Wintun, and third-party license notices. The build workflow verifies SHA-256 checksums before packaging.

The app UI runs normally. Windows asks for administrator approval when you connect, because the VPN service needs permission to create the adapter, update routes, and enable IPv6 leak protection. The installer adds an uninstall entry and removes stale Swock routes and its adapter when uninstalling.

## Download a build

After the `Build Swock for Windows` GitHub Actions workflow finishes, download the `Swock-Windows-Installer` artifact from that workflow run and run `Swock-Setup.exe`.

## Build locally

Install Flutter stable, Go 1.23, Visual Studio with the Desktop development with C++ workload, and Inno Setup 6. Generate the Flutter Windows runner and build/test `windows/core` for Windows amd64. Download and verify the pinned Xray, Sing-box, and Wintun releases, then place `swock_core.exe` and `wintun.dll` next to `Swock.exe`, with the Xray files in `runtime/xray` and Sing-box files plus `wintun.dll` in `runtime/sing-box`. Build the Flutter release and compile `windows/installer/Swock.iss` with `BundleDir` pointing to the release folder.
