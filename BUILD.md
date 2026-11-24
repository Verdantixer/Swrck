# Build guide

## Prerequisites

- Flutter SDK 3.47+
- Android SDK 36 or compatible version
- JDK 17
- Android command-line tools

## Setup

```bash
export PATH="/home/richboybrown/flutter-sdk/bin:$PATH"
flutter doctor
```

If Android SDK components are missing, install the Android platform and build tools with Android Studio or the SDK manager.

## Run the project

```bash
cd /home/richboybrown/Downloads/swock
flutter pub get
flutter run
```

## Build APK

```bash
flutter build apk --debug
# One universal release APK for all configured Android ABIs
scripts/build-android.sh
# Optional ABI-specific APKs
scripts/build-android.sh split
```

## Notes

- The Android project is configured for the `com.swock.vpn.swock` package namespace.
- The app is Android-only and follows the real `VpnService` design model.
- Xray profiles use the bundled Xray-core runtime, native Sing-box JSON profiles use the bundled Sing-box runtime, and SSH profiles use the native SSH full-tunnel implementation.
- Complete core JSON preserves the protocol features supported by the corresponding bundled core. Xray uses the native tun2socks bridge; Sing-box receives the Android TUN descriptor through libbox.
