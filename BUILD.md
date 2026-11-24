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
- Xray profiles use the bundled Xray-core runtime, native Sing-box JSON profiles use the bundled Sing-box runtime, and SSH profiles use the native SSH full-tunnel implementation.
- Complete core JSON preserves the protocol features supported by the corresponding bundled core. Xray uses the native tun2socks bridge; Sing-box receives the Android TUN descriptor through libbox.
- The Windows client supports Xray profiles (including imported Xray JSON), native Sing-box JSON profiles, and legacy SWK2 profiles. SSH profiles are not yet supported on Windows.

## Build Windows installer

The **Build Swock for Windows** GitHub Actions workflow runs on pushes to `main`, or can be started from **Actions → Build Swock for Windows → Run workflow**. Download the `Swock-Windows-Installer` artifact from the completed run and run `Swock-Setup.exe`.

For local builds, install Flutter stable, Go 1.23, Visual Studio with the Desktop development with C++ workload, and Inno Setup 6. See [windows/README.md](./windows/README.md) for details.

## Build unsigned iOS IPA with GitHub Actions

The **Build Unsigned iOS IPA** workflow runs on pushes to `main` or `master`. You can also start it in GitHub under **Actions → Build Unsigned iOS IPA → Run workflow**. Download the `Swock-Unsigned-IPA` artifact from the completed run.

The workflow builds and packages the IPA without an Apple ID, development team, or provisioning profile. To build the unsigned app locally on macOS:

```bash
flutter pub get
flutter build ios --release --no-codesign
```

The unsigned IPA is a build artifact. Installing it on a standard iPhone or iPad requires signing it first; that signing step is separate from building the IPA.
