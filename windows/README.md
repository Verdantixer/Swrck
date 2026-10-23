# Swock VPN for Windows

The Windows client uses the app's native SWK2 VPN protocol over TCP, TLS, WebSocket, or WebSocket TLS transports. It routes IPv4 traffic through a Wintun adapter and blocks IPv6 traffic while connected. Legacy SWK1 and other profile protocols are not supported by this Windows tunnel.

The app must run as administrator so it can create the adapter, update routes, and enable IPv6 leak protection. Windows asks for elevation when Swock starts. The installer adds an uninstall entry and removes stale Swock routes and its adapter when uninstalling.

## Download a build

After the `Build Swock for Windows` GitHub Actions workflow finishes, download the `Swock-Windows-Installer` artifact from that workflow run and run `Swock-Setup.exe`.

## Build locally

Install Flutter stable, Go 1.23, Visual Studio with the Desktop development with C++ workload, and Inno Setup 6. Then generate the Flutter Windows runner, build `windows/core` for Windows amd64, place the verified Wintun 0.14.1 `wintun.dll` next to the core executable, build the Flutter release, and compile `windows/installer/Swock.iss` with `BundleDir` pointing to the Flutter release folder.
