# BlueSSH

High-performance, cross-platform remote-access client integrating SSH, SFTP,
VNC, and RDP with adaptive compression, session recording, and multi-monitor
support.

## Build Status

| Platform | Status | Output |
|----------|--------|--------|
| Android (APK) | ✅ Passing | `dist/BlueSSH-release.apk` (51 MB) |
| Linux (Ubuntu) | ✅ Passing | `ui/build/linux/x64/release/bundle/bluessh` (43 MB) |
| Windows | ⏳ Requires Windows host | — |

## Architecture

```
Flutter UI (Linux/Windows/Android)  ←→  Rust Core Engine (libbluessh)
    dart:ffi / MethodChannel                Tokio + russh
```

## Quick Build

```bash
# Ubuntu — one command
./scripts/build_ubuntu.sh

# Android — one command
./scripts/build_android.sh

# Windows (PowerShell)
.\scripts\build_windows.bat
```

## Automated Watchdog

```bash
# Monitor build_ubuntu.sh and auto-fix errors
./scripts/watchdog/watch_ubuntu.sh

# Background daemon
./scripts/watchdog/watch_ubuntu.sh --daemon
```

See `scripts/watchdog/WATCHDOG.md` for configuration and extending fix logic.

## Project Structure

```
BlueSSH/
├── scripts/
│   ├── build_ubuntu.sh           # Linux desktop build
│   ├── build_android.sh          # Android APK build (Rust NDK + Flutter)
│   ├── build_windows.bat         # Windows desktop build
│   └── watchdog/                 # Auto-fix build watcher system
│       ├── watch_ubuntu.sh       # Linux watchdog (inotify)
│       ├── watch_windows.ps1     # Windows watchdog (FileSystemWatcher)
│       ├── patterns/             # Error pattern databases
│       ├── watchdog.conf         # Linux config
│       └── WATCHDOG.md           # Watchdog documentation
├── engine/
│   ├── Cargo.toml                # Rust dependencies
│   └── src/lib.rs                # Engine: C-ABI + JNI entry points
├── ui/
│   ├── pubspec.yaml              # Flutter dependencies
│   ├── lib/
│   │   ├── main.dart             # App entry point
│   │   ├── screens/              # HomeScreen, TerminalScreen, etc.
│   │   ├── services/             # SessionService, EngineBridge
│   │   └── models/               # HostProfile, SessionState, etc.
│   ├── android/                  # Android project (Kotlin JNI bridge)
│   └── linux/                    # Linux desktop project
├── docs/
│   ├── ARCHITECTURE.md           # Full system design
│   ├── TECH_STACK_DIAGRAM.md     # Mermaid diagrams
│   ├── ENGINE_MODULE.md          # Rust engine details
│   ├── DEPLOYMENT.md             # CI/CD, packaging
│   └── BUILD.md                  # Android build guide
├── installer/
│   ├── windows/product.wxs       # WiX MSI installer
│   └── linux/control             # Debian package control
└── .gitignore                    # Multi-platform ignore rules
```

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| Rust for engine | Memory safety, zero-cost, Tokio async |
| Flutter for UI | Single codebase → Linux, Windows, Android |
| C-ABI bridge | Lowest overhead for desktop FFI |
| JNI bridge | Required for Android MethodChannel |
| xterm 4.0 | Terminal emulator, KeyEvent-compatible |
| russh 0.58 | Pure Rust SSH-2 client |
| zstd compression | 3-5x faster than zlib |

## Documentation

- [Architecture](docs/ARCHITECTURE.md) — system design, protocols, data flows
- [Tech Stack Diagrams](docs/TECH_STACK_DIAGRAM.md) — Mermaid visual diagrams
- [Engine Module](docs/ENGINE_MODULE.md) — Rust module traits and types
- [Deployment](docs/DEPLOYMENT.md) — CI/CD, packaging, security
- [Android Build](docs/BUILD.md) — NDK cross-compilation guide
- [Watchdog](scripts/watchdog/WATCHDOG.md) — auto-fix build monitoring

## License

MIT
