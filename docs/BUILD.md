# BlueSSH Android — Build Guide

## Architecture Overview

```
┌──────────────────────────────────────────────────────┐
│                Flutter UI (Dart)                      │
│  ┌────────┐ ┌──────────┐ ┌──────┐ ┌──────────────┐  │
│  │Home    │ │Terminal  │ │Files │ │Remote Desktop│  │
│  │Screen  │ │Screen    │ │Screen│ │Screen (VNC/  │  │
│  │        │ │(xterm.   │ │(SFTP)│ │ RDP)         │  │
│  └───┬────┘ │ dart)    │ └──┬───┘ └──────┬───────┘  │
│      │      └────┬─────┘   │             │          │
│  ┌───┴───────────┴─────────┴─────────────┴────────┐ │
│  │         SessionService (Riverpod)               │ │
│  │     MethodChannel('com.bluessh/engine')         │ │
│  └─────────────────────┬──────────────────────────┘ │
└────────────────────────┼────────────────────────────┘
                         │ JNI
┌────────────────────────┼────────────────────────────┐
│  Kotlin (EngineBridge.kt + MainActivity.kt)         │
│  EngineBridge → nativeConnect / nativeWrite / ...   │
└────────────────────────┬────────────────────────────┘
                         │ JNI
┌────────────────────────┼────────────────────────────┐
│  Rust Core Engine (libbluessh.so)                   │
│  ┌───────┐ ┌──────┐ ┌─────┐ ┌─────┐ ┌───────────┐ │
│  │ SSH   │ │ SFTP │ │ VNC │ │ RDP │ │ Recording │ │
│  │ russh │ │Custom│ │ rfb │ │iron.│ │ asciinema │ │
│  └───────┘ └──────┘ └─────┘ └─────┘ └───────────┘ │
└────────────────────────────────────────────────────┘
```

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Rust | 1.77+ | Core engine compilation |
| cargo-ndk | latest | Android NDK cross-compilation |
| Android NDK | r26+ | Native toolchain |
| Android SDK | 34 | Android platform tools |
| Java | 17+ | Gradle build system |
| Flutter | 3.19+ | UI framework |

## Quick Start

```bash
# 1. Install Rust Android targets
rustup target add aarch64-linux-android x86_64-linux-android
cargo install cargo-ndk

# 2. Set environment
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/26.1.10909125
export ANDROID_HOME=$HOME/Android/Sdk  # adjust to your path

# 3. Build everything
./scripts/build_android.sh

# 4. Output
ls dist/BlueSSH-release.apk
```

## Step-by-Step Build

### Step 1: Build Rust Engine

```bash
cd engine

# Build for arm64 (physical devices)
cargo ndk -t arm64-v8a -o ../ui/android/app/src/main/jniLibs \
    build --release

# Build for x86_64 (emulator)
cargo ndk -t x86_64 -o ../ui/android/app/src/main/jniLibs \
    build --release
```

This produces:
```
ui/android/app/src/main/jniLibs/
├── arm64-v8a/libbluessh.so   (~5-8 MB)
└── x86_64/libbluessh.so      (~5-8 MB)
```

### Step 2: Build Flutter APK

```bash
cd ui

# Get dependencies
flutter pub get

# Build release APK
flutter build apk --release

# Build App Bundle (for Play Store)
flutter build appbundle --release
```

Output:
```
ui/build/app/outputs/flutter-apk/app-release.apk     (~15-25 MB)
ui/build/app/outputs/bundle/release/app-release.aab   (~12-20 MB)
```

### Step 3: Install on Device

```bash
# Direct install
flutter install

# Or via adb
adb install build/app/outputs/flutter-apk/app-release.apk
```

## Debug Build

```bash
./scripts/build_android.sh --debug
```

Debug builds include:
- Unstripped native symbols
- Debug assertions in Rust
- Flutter debug mode
- Faster compilation

## ABI Selection

```bash
# Only arm64 (most physical devices)
./scripts/build_android.sh --abi arm64-v8a

# Only x86_64 (emulator)
./scripts/build_android.sh --abi x86_64

# Both (default)
./scripts/build_android.sh --abi all
```

## CI/CD Pipeline

The GitHub Actions workflow (`.github/workflows/android.yml`) automates:

1. **Build Rust**: Cross-compile `libbluessh.so` for arm64 and x86_64
2. **Build Flutter**: Analyze, test, build APK and AAB
3. **Sign**: APK signing with release keystore
4. **Release**: Upload to GitHub Releases and Google Play

### Required Secrets

| Secret | Description |
|--------|-------------|
| `ANDROID_SIGNING_KEY` | Base64-encoded keystore |
| `ANDROID_KEY_ALIAS` | Key alias in keystore |
| `ANDROID_KEYSTORE_PASSWORD` | Keystore password |
| `ANDROID_KEY_PASSWORD` | Key password |
| `ANDROID_SERVICE_ACCOUNT_JSON` | Google Play service account |

## Troubleshooting

### "UnsatisfiedLinkError: dlopen failed"
- Ensure the `.so` file is in the correct ABI directory
- Check that the JNI function names match the Kotlin bridge
- Verify `minSdk 26` in build.gradle

### "cargo-ndk not found"
```bash
cargo install cargo-ndk
```

### "NDK not found"
```bash
# Install via sdkmanager
sdkmanager "ndk;26.1.10909125"
export ANDROID_NDK_HOME=$ANDROID_HOME/ndk/26.1.10909125
```

### Large APK size
- The Rust engine with all protocol support is ~5-8 MB compressed
- Use `--abi arm64-v8a` to exclude x86_64 (saves ~5 MB)
- Enable R8/ProGuard minification in release builds (already configured)

## Security Notes

- **APK signing**: Always use a release keystore, never debug keys for distribution
- **ProGuard**: Enabled for release builds — `proguard-rules.pro` preserves JNI bridge
- **Network security**: `network_security_config.xml` enforces TLS for all connections
- **Secrets in memory**: Rust engine uses `zeroize` to clear credentials after use
- **No cleartext**: `android:usesCleartextTraffic="false"` in manifest
