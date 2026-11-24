# Architecture

## Overview

The application follows a layered architecture designed for production quality and clean separation of concerns:

1. Flutter UI layer
2. App services and repositories
3. Typed profile and configuration models
4. Kotlin native VPN bridge
5. Android `VpnService`
6. Network engine abstraction for Xray-core, Sing-box, and SSH

## Dart layer

The Dart side owns:

- App shell and Material 3 theme
- Profile and transport configuration models
- Persistence and import/export logic
- Clipboard and settings handling
- UI and navigation

It intentionally does not implement actual VPN traffic routing. Instead, it communicates with the native Android layer via `MethodChannel` and `EventChannel`.

## Kotlin layer

The Android layer owns:

- Permission handling
- Foreground service lifecycle
- VpnService setup and shutdown
- Statistics and network state reporting
- Connection orchestration for the real engine

The main integration entry points are:

- `MyVpnService.kt`
- `VpnController.kt`
- `FlutterVpnBridge.kt`

## Networking engine abstraction

The engine boundary is intentionally isolated:

- `VpnEngine`: general VPN lifecycle API
- `ProfileVpnEngine`: dispatches SSH profiles to the native SSH tunnel, Sing-box profiles to libbox, and Xray/proxy profiles to Xray-core
- `XrayCoreEngine`: prepares the Xray configuration, protects Android sockets, starts Xray with a private SOCKS inbound, and manages the native runtime lifecycle
- `Tun2SocksBridge`: passes the Android TUN descriptor to the bundled tun2socks process and connects it to the active local SOCKS endpoint
- `SshVpnEngine`: uses a local SOCKS5 listener backed by SSH `direct-tcpip` channels; optional UDP traffic uses a BadVPN UDPGW service over SSH forwarding. It does not execute a remote helper or require a server-side TUN/root setup.
- Complete Xray JSON preserves Xray outbounds, routing, DNS, and protocol-specific options. Xray owns its private SOCKS inbound and the TUN-to-SOCKS bridge.
- Native Sing-box JSON preserves its outbounds, endpoints, routing, DNS, and protocol-specific options. The Android adapter supplies the TUN inbound and delegates configuration validation to libbox.
- Supported protocol types and features depend on the versions of the bundled Xray and Sing-box cores.

## Bridge API

The Flutter app calls into Android via method names such as:

- `connect`
- `disconnect`
- `getStatus`
- `getStatistics`
- `testConnection`
- `getNetworkInfo`

The native service can emit events including:

- `connectionStateChanged`
- `downloadSpeedChanged`
- `uploadSpeedChanged`
- `latencyChanged`
- `vpnError`
- `logMessage`

## Typical flow

1. User selects a profile in Flutter.
2. Flutter serializes the profile to JSON.
3. Dart invokes native method channel.
4. Kotlin `VpnController` dispatches to the engine.
5. The engine prepares the tunnel or socket and reports the resulting status back to Dart.
6. UI updates from the event stream.

## Security boundaries

- Secrets remain in secure storage or encrypted profile files.
- Logs and error messages never print plaintext credentials.
- Imports are validated before being accepted.
- Transport logic is isolated from UI code.
