# Swock VPN

Swock is an Android-focused Flutter + Kotlin VPN client built around a clear separation between the UI, profile model, and the native Android VPN layer.

## Overview

This project is intentionally structured to support a real Android `VpnService` implementation and a separate networking engine abstraction. The UI is built in Dart with Material 3, while the Android layer is implemented in Kotlin. The native layer exposes a bridge to the Flutter app for actions such as connection, disconnection, status checks, and traffic statistics.

## Design goals

- Android-only Flutter UI with Material 3
- Kotlin `VpnService` foundation with native lifecycle handling
- Xray-core, Sing-box, and SSH VPN engines
- Strong typing and explicit configuration models
- Export, import, profile management, and secure storage for sensitive data
- Clean separation between Flutter UI and native networking

## Folder structure

- `lib/` – Dart UI, models, services, and theme
- `android/app/src/main/kotlin/...` – Kotlin VPN service and native bridge layer

## Required permissions

Add the following permissions to the Android manifest when enabling the actual VPN service:

```xml
<uses-permission android:name="android.permission.INTERNET" />
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />
```

For a true VPN service, the app must also ask the user to enable the VPN permission from Android and start the service with `VpnService.prepare(...)` before attaching the tunnel.

## Build

```bash
export PATH="/home/richboybrown/flutter-sdk/bin:$PATH"
cd /home/richboybrown/Downloads/swock
flutter pub get
flutter analyze
flutter build apk --debug
```

## VPN engines

Xray profiles use the bundled Xray-core runtime, native Sing-box JSON profiles
use the bundled Sing-box runtime, and SSH profiles use the native SSH
full-tunnel implementation. Complete core JSON preserves the protocol features
supported by the corresponding bundled core. Xray uses the native tun2socks
bridge; SSH uses that same bridge with its local SSH-backed SOCKS5 endpoint;
Sing-box receives the Android TUN descriptor through libbox. The pinned
runtimes and license notices are in `android/app/libs/`.

SSH uses an app-local SOCKS5 listener and standard SSH TCP forwarding, so it
does not require a remote helper executable or root access on the SSH server.
DNS requests are forwarded over TCP when the optional UDP gateway is disabled.
Other UDP traffic requires a BadVPN UDPGW service reachable over SSH forwarding.
The Advanced settings screen also has a global **Enable IPv6** switch; when off,
IPv6 is captured and blocked inside the VPN rather than sent outside it.

Legacy native Swock tunnel profiles are no longer supported. Import a supported
proxy share link, Xray JSON, or native Sing-box JSON configuration instead.

Profile files use the `.dvs` extension. Files can be imported from device storage
and exported through Android's file picker. Export can mark a profile read-only
in Swock, set an expiration date, and optionally protect the file with a
password. Password-protected files use PBKDF2-HMAC-SHA256, AES-256-CBC, and an
HMAC-SHA256 integrity check. Expired profiles cannot connect. Locked imported
profiles can connect while valid, but the app only allows them to be deleted.

## Security

- Sensitive profile data should be stored in Android Keystore-backed secure storage where practical.
- Credentials and secrets are not logged.
- Import validation is required before accepting a profile.
- Password-protected `.dvs` exports use authenticated encryption.
