# BlueSSH

A high-performance, cross-platform SSH client with full Bitvise-compatible features. Native implementations for each platform:

- **Android**: Pure Kotlin/Java with Material Design 3 UI
- **Linux/Windows**: Native C++ with Qt6 GUI

## Features

### Core Protocols
- **SSH-2** terminal access with xterm-256color emulation
- **SFTP** file transfer with progress tracking
- **SCP** file copy support
- **Port Forwarding**: Local, Remote, Dynamic (SOCKS5)
- **X11 Forwarding**
- **SSH Agent Forwarding**

### Authentication
- Password authentication
- Public key authentication (RSA, DSA, ECDSA, Ed25519)
- Keyboard-interactive authentication
- MFA/TOTP support
- GSSAPI/Kerberos authentication
- Certificate-based authentication

### Terminal
- Full xterm-256color emulation
- True color (24-bit) support
- Unicode/UTF-8 support
- Mouse tracking support
- Bracketed paste mode
- 10,000+ line scrollback buffer
- Session recording (asciinema format)
- Search in terminal
- Customizable themes and fonts

### File Transfer (SFTP)
- Directory browsing with file details
- Upload/download with progress
- Drag & drop support
- Resume interrupted transfers
- File permissions management
- Remote file editing
- Transfer queue management

### Session Management
- Saved host profiles
- Multi-tab sessions
- Session groups/tags
- Jump host/bastion support
- Auto-reconnect with exponential backoff
- Connection keepalive
- Session recording & playback

### Security
- Known hosts verification
- Host key fingerprint display
- Encrypted credential storage
- Password memory zeroization
- SSH key generation & management
- Certificate management

### Advanced Features (Bitvise-compatible)
- **Terminal Shell**: Full interactive shell with PTY
- **SFTP Client**: Graphical file manager
- **Port Forwarding Manager**: Visual tunnel configuration
- **Remote Command Execution**: Run commands without interactive shell
- **Scripting**: Execute scripts on connection
- **Environment Variables**: Per-session environment setup
- **Terminal Logging**: Automatic session logging
- **Reconnection**: Seamless reconnection handling
- **Multi-protocol**: SSH, SFTP, SCP in single client
- **Compression**: Adaptive compression levels
- **Performance**: Optimized for high-latency connections

## Architecture

```
BlueSSH/
├── android/              # Native Android app (Kotlin)
│   ├── app/
│   │   ├── src/main/java/com/bluessh/
│   │   │   ├── core/         # SSH engine, connection management
│   │   │   ├── ui/           # Activities, fragments, views
│   │   │   ├── models/       # Data models
│   │   │   ├── services/     # Background services
│   │   │   └── utils/        # Utilities
│   │   └── src/main/res/     # Resources
│   └── build.gradle.kts
│
├── desktop/              # Native C++ desktop app
│   ├── src/
│   │   ├── core/         # SSH engine, connection management
│   │   ├── ui/           # Qt GUI components
│   │   ├── models/       # Data models
│   │   └── utils/        # Utilities
│   └── CMakeLists.txt
│
├── shared/               # Shared resources
│   ├── docs/             # Documentation
│   └── assets/           # Shared assets
│
└── scripts/              # Build scripts
```

## Build Instructions

### Android
```bash
cd android
./gradlew assembleDebug    # Debug APK
./gradlew assembleRelease  # Release APK
```

### Linux
```bash
cd desktop
mkdir build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
make -j$(nproc)
```

### Windows
```bash
cd desktop
mkdir build && cd build
cmake .. -G "Visual Studio 17 2022" -A x64
cmake --build . --config Release
```

## Dependencies

### Android
- **SSH Library**: Apache MINA SSHD
- **Terminal**: termux-terminal-view
- **UI**: Material Design 3, AndroidX
- **Storage**: EncryptedSharedPreferences
- **Async**: Kotlin Coroutines

### Desktop (C++)
- **SSH Library**: libssh2
- **Terminal**: libvterm
- **GUI**: Qt6
- **Crypto**: OpenSSL
- **Compression**: zlib, libzstd

## License

MIT License
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
