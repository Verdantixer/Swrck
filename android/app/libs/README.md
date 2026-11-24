# Bundled Xray runtime

`libXray.aar` is based on the Android library published by the XTLS/libXray project at release `v26.11.9` (Android release archive `libxray-android.zip`). That build pins Xray-core `v26.11.9`.

The bundled AAR has been trimmed to the `arm64-v8a` native library only. The `armeabi-v7a`, `x86`, and `x86_64` libraries are intentionally omitted to reduce app size. The release build is also restricted to `arm64-v8a` in `app/build.gradle.kts`.

The upstream release archive SHA-256 before trimming was:
`1b1aa12124a7112af983a6cea74c77f27aadc6b650acf3c5a57019619ba9fa48`.

The bundled arm64-only AAR SHA-256 is:
`E0A2DF68EC17B0081823724A6EA2F964976BC30C8C68D173212959E0B8F44EEB`.

The runtime is loaded as an app-local AAR by `app/build.gradle.kts`. Its upstream MIT license is included in `LICENSE-libXray.txt`; the Xray-core MIT license is included in `LICENSE-Xray-core.txt`.

Upstream projects:

- https://github.com/XTLS/libXray
- https://github.com/XTLS/Xray-core
