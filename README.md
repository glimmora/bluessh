# BlueSSH

A high-performance, cross-platform remote-access client that integrates SSH, SFTP, VNC, and RDP into a single application. Features adaptive compression, session recording, clipboard sharing, and multi-monitor support.

## Overview

BlueSSH separates a lightweight, platform-native UI (built with Flutter) from a core networking engine (written in Rust). This architecture delivers low-latency I/O, memory safety, and a single codebase that targets Linux, Windows, and Android.

```
┌──────────────────────────────┐     ┌──────────────────────────────┐
│      Flutter UI Layer        │     │      Rust Core Engine        │
│                              │     │                              │
│  Terminal · Files · Desktop  │◄───►│  SSH · SFTP · VNC · RDP     │
│                              │     │                              │
│  dart:ffi  (Linux/Windows)   │     │  Tokio async runtime         │
│  MethodChannel (Android)     │     │  russh 0.58 (SSH-2)          │
└──────────────────────────────┘     │  zstd adaptive compression   │
                                     └──────────────────────────────┘
```

## Build Status

| Platform | Status | Output |
|----------|--------|--------|
| Android (APK) | ✅ Passing | `dist/BlueSSH-arm64-v8a-release.apk` (19 MB) |
| Linux (Ubuntu) | ✅ Passing | `dist/BlueSSH-linux-x64-release.tar.gz` (16 MB) |
| Linux (Debian) | ✅ Passing | `dist/BlueSSH-0.1.0-amd64.deb` (13 MB) |
| Windows | ⏳ Requires a Windows host | — |

## Quick Start

### Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Rust | 1.77+ | Core engine compilation |
| Flutter | 3.19+ | UI framework |
| Android NDK | r26+ | Cross-compilation for Android |
| Java | 17+ | Gradle build system |
| `cargo-ndk` | latest | Rust → Android native libraries |

### Build Commands

```bash
# Ubuntu / Debian desktop
./scripts/build_ubuntu.sh

# Android APK (arm64 only)
./scripts/build_android.sh --abi arm64-v8a

# Android APK (all architectures)
./scripts/build_android.sh --abi all

# Windows desktop (run on Windows)
.\scripts\build_windows.bat
```

### Build Outputs

After a successful build, distribution artifacts are placed in the `dist/` directory:

```
dist/
├── BlueSSH-linux-x64-release.tar.gz      # Portable Linux bundle
├── BlueSSH-0.1.0-amd64.deb              # Debian package
├── BlueSSH-arm64-v8a-release.apk         # Android 64-bit ARM
├── BlueSSH-armeabi-v7a-release.apk       # Android 32-bit ARM
├── BlueSSH-x86_64-release.apk            # Android 64-bit x86
├── BlueSSH-x86-release.apk               # Android 32-bit x86
└── BlueSSH-universal-release.apk         # Android universal
```

## Project Structure

```
BlueSSH/
├── engine/
│   ├── Cargo.toml                          # Rust dependencies
│   └── src/lib.rs                          # C-ABI and JNI entry points
│
├── ui/
│   ├── pubspec.yaml                        # Flutter dependencies
│   ├── lib/
│   │   ├── main.dart                       # Application entry point
│   │   ├── screens/                        # HomeScreen, TerminalScreen, etc.
│   │   ├── services/                       # SessionService, EngineBridge
│   │   └── models/                         # HostProfile, SessionState
│   ├── android/                            # Android project (Kotlin JNI bridge)
│   └── linux/                              # Linux desktop project
│
├── scripts/
│   ├── build_ubuntu.sh                     # Linux build script
│   ├── build_android.sh                    # Android build script
│   ├── build_windows.bat                   # Windows build script
│   └── watchdog/                           # Automated build monitoring
│       ├── watch_ubuntu.sh                 # Linux watchdog (inotify)
│       ├── watch_windows.ps1               # Windows watchdog (FileSystemWatcher)
│       ├── patterns/                       # Error pattern databases
│       ├── watchdog.conf                   # Linux configuration
│       └── WATCHDOG.md                     # Watchdog documentation
│
├── docs/
│   ├── ARCHITECTURE.md                     # System design and protocol details
│   ├── TECH_STACK_DIAGRAM.md               # Mermaid architecture diagrams
│   ├── ENGINE_MODULE.md                    # Rust engine module reference
│   ├── DEPLOYMENT.md                       # CI/CD and packaging
│   └── BUILD.md                            # Android cross-compilation guide
│
├── installer/
│   ├── windows/product.wxs                 # WiX MSI installer definition
│   └── linux/control                       # Debian package metadata
│
├── .gitignore                              # Multi-platform ignore rules
└── README.md                               # This file
```

## Architecture

### Core Engine (Rust)

The engine is a single Rust crate compiled as a shared library (`libbluessh.so` on Linux, `bluessh.dll` on Windows, `libbluessh.so` via NDK on Android). It exposes a C-ABI for desktop platforms and JNI functions for Android.

| Component | Crate | Description |
|-----------|-------|-------------|
| Async runtime | `tokio` | Multi-threaded, work-stealing scheduler |
| SSH client | `russh` 0.58 | Pure Rust SSH-2 implementation |
| TLS | `rustls` 0.23 | TLS 1.3 with ring cryptography |
| Compression | `zstd` 0.13 | Adaptive dictionary-based compression |
| Serialization | `serde` + `bincode` | Fast binary framing for engine↔UI |
| Memory safety | `zeroize` | Zeroes credentials from heap after use |

### UI Layer (Flutter)

The Flutter UI shares a single Dart codebase with platform-specific bridge implementations:

| Platform | Bridge Method | Native Library |
|----------|--------------|----------------|
| Linux | `dart:ffi` | `libbluessh.so` |
| Windows | `dart:ffi` | `bluessh.dll` |
| Android | `MethodChannel` + JNI | `libbluessh.so` (NDK) |

### Design Decisions

| Decision | Rationale |
|----------|-----------|
| Rust for the engine | Memory safety without garbage collection; zero-cost abstractions; native async with Tokio |
| Flutter for the UI | Single codebase compiles to Linux, Windows, and Android; Material Design 3 out of the box |
| C-ABI bridge (desktop) | Lowest overhead for FFI — no serialization cost, direct pointer passing |
| JNI bridge (Android) | Required by the Android platform for native method dispatch through `MethodChannel` |
| xterm 4.0 | Terminal emulator with full `KeyEvent` support for the Flutter master channel |
| zstd compression | 3–5× faster than zlib at comparable compression ratios; adaptive level selection based on link speed |

## Automated Build Watchdog

The watchdog monitors build scripts for file changes, executes them automatically, detects common error patterns, and applies predefined fixes.

```bash
# Interactive mode
./scripts/watchdog/watch_ubuntu.sh

# Background daemon
./scripts/watchdog/watch_ubuntu.sh --daemon

# Stop the daemon
kill $(cat scripts/watchdog/logs/watchdog.pid)
```

The watchdog includes 34 built-in error patterns covering missing dependencies, permission errors, disk space issues, linker failures, and package manager conflicts. See [`scripts/watchdog/WATCHDOG.md`](scripts/watchdog/WATCHDOG.md) for configuration, adding custom patterns, and extending fix logic.

## Documentation

| Document | Description |
|----------|-------------|
| [Architecture](docs/ARCHITECTURE.md) | System design, protocol specifications, data-flow diagrams |
| [Tech Stack Diagrams](docs/TECH_STACK_DIAGRAM.md) | Visual Mermaid diagrams for system, sequence, and CI/CD |
| [Engine Module](docs/ENGINE_MODULE.md) | Rust module traits, types, and concurrency model |
| [Deployment](docs/DEPLOYMENT.md) | CI/CD pipelines, packaging, self-update, security hardening |
| [Android Build](docs/BUILD.md) | NDK cross-compilation and APK generation guide |
| [Watchdog](scripts/watchdog/WATCHDOG.md) | Auto-fix build monitoring configuration |

## License

MIT
