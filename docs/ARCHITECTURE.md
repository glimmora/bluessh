# BlueSSH — Architecture Specification

## 1. Overview

BlueSSH is a high-performance, cross-platform remote-access client integrating
SSH, SFTP, VNC, and RDP into a single application. The architecture enforces a
strict separation between a **core networking engine** (Rust) and a **platform-
native UI** (Flutter), communicating over a lightweight FFI/Platform-Channel
bridge.

### Design Goals

| Goal | Strategy |
|------|----------|
| Minimal bandwidth | Adaptive zlib / zstd compression, delta-encoded screen updates |
| Low latency | Rust async runtime (Tokio), zero-copy buffers, io_uring on Linux |
| Cross-platform | Single Rust core, Flutter UI targeting Windows, Ubuntu, Android |
| Session resilience | Multiplexed keep-alive, automatic reconnect with state replay |
| Security | Ed25519/ECDSA key auth, TOTP/FIDO2 MFA, mTLS between engine & UI |
| Observability | Structured session recording (asciinema + custom binary) |

---

## 2. Technology Stack Diagram

```
┌───────────────────────────────────────────────────────────────────┐
│                         Flutter UI Layer                          │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────────────┐ │
│  │  Terminal    │  │  File Manager│  │  Remote Desktop (VNC/RDP)│ │
│  │  Widget      │  │  (SFTP)      │  │  Multi-Monitor Canvas    │ │
│  └──────┬──────┘  └──────┬───────┘  └───────────┬──────────────┘ │
│         │                │                       │                │
│  ┌──────┴────────────────┴───────────────────────┴──────────────┐ │
│  │              Platform Channel / FFI Bridge                    │ │
│  │  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌─────────────┐  │ │
│  │  │ Windows  │  │  Linux   │  │ Android  │  │ Shared Dart │  │ │
│  │  │ FFI      │  │  FFI     │  │ MethodCh │  │ Interface   │  │ │
│  │  └──────────┘  └──────────┘  └──────────┘  └─────────────┘  │ │
│  └──────────────────────────┬───────────────────────────────────┘ │
└─────────────────────────────┼─────────────────────────────────────┘
                              │  Unix socket / Named pipe / JNI
┌─────────────────────────────┼─────────────────────────────────────┐
│                      Rust Core Engine                              │
│  ┌──────────────────────────┴───────────────────────────────────┐ │
│  │                     Async Runtime (Tokio)                     │ │
│  │  ┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐            │ │
│  │  │  SSH    │ │  SFTP   │ │  VNC    │ │  RDP    │            │ │
│  │  │ russh  │ │ built-in│ │ rfb     │ │ ironrdp │            │ │
│  │  └────┬────┘ └────┬────┘ └────┬────┘ └────┬────┘            │ │
│  │       │           │           │           │                  │ │
│  │  ┌────┴───────────┴───────────┴───────────┴──────────────┐   │ │
│  │  │          Session Manager / Event Bus                   │   │ │
│  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐ │   │ │
│  │  │  │Clipboard │ │Recording │ │  Compr.  │ │Keep-Alive│ │   │ │
│  │  │  │ Sharing  │ │ Engine   │ │ zstd/zlib│ │ Manager  │ │   │ │
│  │  │  └──────────┘ └──────────┘ └──────────┘ └──────────┘ │   │ │
│  │  └───────────────────────────────────────────────────────┘   │ │
│  └──────────────────────────────────────────────────────────────┘ │
└───────────────────────────────────────────────────────────────────┘
                              │
                     ┌────────┴────────┐
                     │  Remote Server  │
                     └─────────────────┘
```

---

## 3. Component Architecture

### 3.1 Rust Core Engine

The engine is a single Rust crate (`bluessh-engine`) compiled as:

| Target | Artifact | Bridge |
|--------|----------|--------|
| Windows | `bluessh.dll` (C-ABI) | `dart:ffi` |
| Linux | `libbluessh.so` (C-ABI) | `dart:ffi` |
| Android | `libbluessh.so` (via JNI) | `MethodChannel` through `bluessh_jni.c` |

#### Key Crates

| Crate | Purpose |
|-------|---------|
| `tokio` 1.x | Async runtime, multi-threaded scheduler |
| `russh` 0.40+ | SSH-2 protocol client (channels, exec, shell) |
| `ironrdp` 0.5+ | RDP client (PDU, GFX, audio redirection) |
| `rfb` / custom VNC | RFB 3.8 protocol client with Tight/ZRLE decoding |
| `zstd` | Dictionary-based compression (level 1-19 adaptive) |
| `flate2` | zlib/gzip fallback for legacy servers |
| `ring` / `rustls` | TLS 1.3, X.509, Ed25519, ECDSA-P256 |
| `serde` + `bincode` | Fast serialization for engine↔UI messages |
| `tracing` | Structured logging with `tracing-subscriber` |

#### Module Layout

```
engine/
├── Cargo.toml
├── src/
│   ├── lib.rs            # Public C-ABI / JNI entry points
│   ├── bridge/           # FFI & JNI marshalling layer
│   ├── session/          # Session manager, event bus, state machine
│   ├── ssh/              # SSH channel logic (shell, exec, port-forward)
│   ├── sftp/             # SFTP v3 operations, parallel transfers
│   ├── vnc/              # RFB client, framebuffer, input events
│   ├── rdp/              # IronRDP integration, GFX pipeline
│   ├── clipboard/        # Cross-platform clipboard bridge
│   ├── recording/        # Session recorder (asciinema + binary)
│   ├── compression/      # Adaptive compression selection
│   ├── keepalive/        # Heartbeat, dead-peer detection
│   ├── auth/             # Key-agent, MFA, certificate store
│   ├── fir/              # Firmware-Update (self-update) module
│   └── config/           # TOML config, host profiles
```

#### Core Traits

```rust
// engine/src/session/mod.rs
pub trait RemoteProtocol: Send + Sync {
    async fn connect(&mut self, host: &HostProfile) -> Result<SessionId>;
    async fn authenticate(&mut self, creds: &Credentials) -> Result<()>;
    async fn disconnect(&mut self) -> Result<()>;
    fn protocol_type(&self) -> ProtocolType; // SSH | SFTP | VNC | RDP
}

pub trait StreamAdapter: Send + Sync {
    async fn read_frame(&mut self) -> Result<Frame>;
    async fn write_frame(&mut self, frame: Frame) -> Result<()>;
    fn set_compression(&mut self, level: CompressionLevel);
    fn latency_ms(&self) -> u32;
}
```

### 3.2 Flutter UI Layer

The Flutter UI shares **one codebase** (`ui/`) with platform-specific entry points:

```
ui/
├── lib/
│   ├── main.dart
│   ├── app.dart
│   ├── screens/
│   │   ├── home_screen.dart           # Connection manager
│   │   ├── terminal_screen.dart       # xterm.dart-based terminal
│   │   ├── file_manager_screen.dart   # SFTP browser
│   │   ├── remote_desktop_screen.dart # VNC/RDP viewer
│   │   └── settings_screen.dart       # Preferences, key management
│   ├── widgets/
│   │   ├── terminal_widget.dart       # Terminal emulator widget
│   │   ├── rdp_canvas.dart            # CustomPainter for RDP frames
│   │   ├── vnc_canvas.dart            # CustomPainter for VNC frames
│   │   ├── file_list.dart             # SFTP file browser
│   │   └── toolbar.dart               # Session toolbar
│   ├── services/
│   │   ├── engine_bridge.dart         # Dart↔Rust FFI/MethodChannel
│   │   ├── session_service.dart       # Session lifecycle management
│   │   ├── recording_service.dart     # Playback/recording UI logic
│   │   └── update_service.dart        # Auto-update checker
│   ├── models/
│   │   ├── host_profile.dart
│   │   ├── session_state.dart
│   │   └── transfer_progress.dart
│   └── platform/
│       ├── bridge_windows.dart        # dart:ffi bindings
│       ├── bridge_linux.dart          # dart:ffi bindings
│       └── bridge_android.dart        # MethodChannel bindings
├── android/
├── linux/
├── windows/
├── pubspec.yaml
```

---

## 4. Protocol Details

### 4.1 SSH — Terminal & Command Execution

| Aspect | Implementation |
|--------|---------------|
| Library | `russh` 0.40+ |
| Protocol | SSH-2 (RFC 4251–4254) |
| Key Exchange | curve25519-sha256, ecdh-sha2-nistp256 |
| Ciphers | chacha20-poly1305@openssh.com, aes256-gcm@openssh.com |
| MAC | implicit (AEAD) or hmac-sha2-256 |
| Auth | publickey (Ed25519, ECDSA, RSA), password, keyboard-interactive |
| Channels | session (shell, exec), direct-tcpip (port-forward) |
| Terminal | PTY allocation via `pty-req`, xterm-256color |

### 4.2 SFTP — File Transfer

| Aspect | Implementation |
|--------|---------------|
| Library | Custom SFTP v3 over `russh` channel |
| Protocol | SFTP v3 (draft-ietf-secsh-filexfer-02) |
| Parallelism | 8 concurrent transfer workers per session |
| Chunk Size | Adaptive 32KB–1MB based on RTT |
| Compression | zstd dictionary trained on common file types |
| Resume | Checkpoint-based (SHA-256 of transferred chunks) |
| Integrity | Per-file SHA-256 verification post-transfer |

### 4.3 VNC — Virtual Network Computing

| Aspect | Implementation |
|--------|---------------|
| Library | Custom RFB 3.8 client (`rfb` crate) |
| Protocol | RFB 3.8 (rfbproto.org) |
| Encodings | Tight (JPEG + zlib), ZRLE, Hextile, Raw |
| Auth | VNC password, VeNCrypt (TLS), Apple Remote Desktop |
| Display | Flutter `CustomPainter` rendering from shared `Image` buffer |
| Input | Key events via `RawKeyboard`, pointer via `GestureDetector` |
| Multi-Monitor | Extended desktop via `rfb::ClientFence` + monitor rects |

### 4.4 RDP — Remote Desktop Protocol

| Aspect | Implementation |
|--------|---------------|
| Library | `ironrdp` 0.5+ |
| Protocol | RDP 10.x (ITU-T T.128, MS-RDPBCGR) |
| Transport | TLS 1.3 (via `rustls`) wrapped in X.224/MCS/SEC |
| Graphics | RFX, NSCodec, progressive codec |
| Audio | Audio output redirection (PCM over dynamic virtual channel) |
| Printing | Remote printing via RDP print virtual channel (MS-RDPEPC) |
| Multi-Monitor | Display Update PDU with monitor layout |
| Clipboard | CLIPRDR channel (MS-RDPECLIP) for text + file copy |

---

## 5. Engine ↔ UI Bridge

### 5.1 Message Protocol

All communication uses a binary framed protocol:

```
┌──────────┬──────────┬──────────┬──────────────┐
│  magic   │  msg_id  │  length  │  payload     │
│  2 bytes │  4 bytes │  4 bytes │  N bytes     │
│  0xBL55  │  u32 LE  │  u32 LE  │  bincode     │
└──────────┴──────────┴──────────┴──────────────┘
```

### 5.2 Platform-Specific Bridges

#### Windows & Linux — `dart:ffi`

```dart
// ui/lib/platform/bridge_windows.dart (identical for linux)
import 'dart:ffi';
import 'dart:io';

typedef EngineConnectC = Int32 Function(Pointer<Utf8> host, Pointer<Utf8> port);
typedef EngineConnect = int Function(Pointer<Utf8> host, Pointer<Utf8> port);

final DynamicLibrary _engine = Platform.isWindows
    ? DynamicLibrary.open('bluessh.dll')
    : DynamicLibrary.open('libbluessh.so');

final EngineConnect engineConnect =
    _engine.lookupFunction<EngineConnectC, EngineConnect>('engine_connect');
```

The engine writes frames into a shared memory ring buffer. The Flutter UI
polls via `dart:ffi` callbacks registered with `NativeCallable`.

#### Android — `MethodChannel` + JNI

```kotlin
// ui/android/app/src/main/kotlin/com/bluessh/EngineBridge.kt
class EngineBridge : MethodCallHandler {
    companion object {
        init { System.loadLibrary("bluessh") }
    }
    external fun nativeConnect(host: String, port: String): Int
    // ... JNI bridge methods
}
```

Flutter side:

```dart
const _channel = MethodChannel('com.bluessh/engine');
final result = await _channel.invokeMethod('connect', {'host': host, 'port': port});
```

### 5.3 Event Flow

```
Flutter UI                          Rust Engine
    │                                    │
    │──── connect(host, port) ──────────▶│
    │                                    │── TCP/TLS connect
    │                                    │── SSH handshake
    │◀── SessionState.connected ─────────│
    │                                    │
    │──── send_keys(input) ─────────────▶│
    │                                    │── SSH channel write
    │                                    │
    │◀── TerminalFrame(data) ────────────│── SSH channel read
    │                                    │── compress + frame
    │                                    │
    │──── sftp_list(path) ──────────────▶│
    │◀── FileListing(items) ────────────│── SFTP readdir
```

---

## 6. Bandwidth Optimization

### 6.1 Adaptive Compression

```
            Bandwidth < 1 Mbps         1–10 Mbps          > 10 Mbps
            ──────────────────     ──────────────────    ──────────────────
Terminal:   zstd level 9          zstd level 3          zstd level 1
VNC:        Tight + JPEG Q=30    Tight + JPEG Q=60     Raw / Hextile
RDP:        NSCodec               RFX                   Progressive
SFTP:       zstd level 19         zstd level 6          No compression
```

The engine samples RTT every 5 seconds and adjusts:

```rust
// engine/src/compression/mod.rs
pub fn select_level(rtt_ms: u32, bandwidth_kbps: u32) -> CompressionLevel {
    match (rtt_ms, bandwidth_kbps) {
        (_, b) if b < 1024 => CompressionLevel::ZstdHigh,
        (r, _) if r > 200  => CompressionLevel::ZstdLow,
        _                  => CompressionLevel::ZstdMed,
    }
}
```

### 6.2 Delta Streaming

- **Terminal**: Only transmit cell diffs (row-level dirty flags)
- **VNC**: Tight encoding with incremental rectangle updates; compare
  framebuffer hash to skip unchanged regions
- **RDP**: NSCodec tile-level delta; progressive refinement for slow links

### 6.3 Bandwidth Estimation

Uses a Kalman-filter-based estimator tracking TCP segments:

```rust
pub struct BandwidthEstimator {
    samples: VecDeque<(Instant, u64)>,
    ema_bps: f64,
    alpha: f64, // smoothing factor 0.125 (RFC 6298)
}
```

---

## 7. Keep-Alive & Session Recovery

### 7.1 Keep-Alive Strategy

```
┌──────────────────────────────────────────────────────┐
│               Keep-Alive State Machine                │
│                                                      │
│  ┌─────────┐   pong OK    ┌──────────┐               │
│  │Healthy  │─────────────▶│  Idle    │               │
│  └────┬────┘              └────┬─────┘               │
│       │                        │                     │
│       │ 3 misses               │ 60s timeout         │
│       ▼                        ▼                     │
│  ┌─────────┐              ┌──────────┐               │
│  │Degraded │──reconnect──▶│Recovering│               │
│  └─────────┘              └──────────┘               │
└──────────────────────────────────────────────────────┘
```

- **SSH**: `ServerAliveInterval` ping every 30s (global-request keepalive@openssh.com)
- **VNC**: `FramebufferUpdateRequest` with incremental=1 every 15s
- **RDP**: `KeepAlive PDU` every 30s per MS-RDPBCGR §3.3.5.4
- **Engine-level**: Application-layer heartbeat over bridge every 10s

### 7.2 Session Recovery

```rust
pub struct SessionSnapshot {
    pub session_id: SessionId,
    pub protocol: ProtocolType,
    pub host: HostProfile,
    pub terminal_buffer: Vec<u8>,      // last 10K lines
    pub cursor_pos: (u16, u16),
    pub env_vars: HashMap<String, String>,
    pub working_dir: String,
    pub sftp_cwd: String,
    pub vnc_encodings: Vec<EncodingType>,
    pub timestamp: SystemTime,
}

pub struct RecoveryEngine {
    max_attempts: u32,       // default 5
    backoff: ExponentialBackoff, // 1s, 2s, 4s, 8s, 16s
    snapshot: Option<SessionSnapshot>,
}
```

On disconnect:
1. Snapshot current session state
2. Attempt reconnection with exponential backoff (1s → 32s)
3. Re-authenticate using stored credentials
4. Replay terminal state (screen dump via `cat`)
5. Restore SFTP working directory
6. Resume VNC/RDP stream with fresh framebuffer request

---

## 8. Authentication & Security

### 8.1 Key Management

```
┌─────────────────────────────────────────┐
│            Key Store (per-OS)            │
│  ┌────────────────────────────────────┐ │
│  │ Windows: DPAPI + Credential Locker │ │
│  │ Linux:   GNOME Keyring / KWallet   │ │
│  │ Android: Android Keystore          │ │
│  └────────────────────────────────────┘ │
│                                         │
│  Key Types Supported:                   │
│  • Ed25519 (preferred)                  │
│  • ECDSA P-256 / P-384                 │
│  • RSA 2048 / 4096                     │
│  • FIDO2 U2F (via CTAP2 bridge)        │
└─────────────────────────────────────────┘
```

### 8.2 MFA Flow

```
Client                    Engine                   Server
  │                          │                        │
  │── password ─────────────▶│── SSH auth request ───▶│
  │                          │                        │
  │◀── MFA challenge ────────│◀── keyboard-interactive │
  │── TOTP code ────────────▶│── TOTP verify ────────▶│
  │                          │                        │
  │◀── Auth success ─────────│◀── SSH_USERAUTH_SUCCESS │
```

Supported MFA methods:
- TOTP (RFC 6238) — stored encrypted in key store
- FIDO2/U2F hardware keys (via `libfido2` FFI on desktop, CTAP2 on Android)
- Certificate-based auth (X.509 user certificates via SSH CA)

### 8.3 Transport Security

| Layer | Implementation |
|-------|---------------|
| SSH transport | Built-in encryption (see §4.1) |
| RDP transport | TLS 1.3 via `rustls`, NLA with CredSSP |
| VNC transport | VeNCrypt sub-type TLSNone/TLSPlain |
| Engine↔UI | mTLS on Unix socket / named pipe |

---

## 9. Session Recording

### 9.1 Recording Formats

| Format | Use Case | File Extension |
|--------|----------|----------------|
| Asciinema v2 | Terminal replay | `.cast` |
| Binary VNC | VNC session replay | `.vnc-rec` |
| Binary RDP | RDP session replay | `.rdp-rec` |
| Structured log | Audit trail (JSON lines) | `.audit.jsonl` |

### 9.2 Recording Pipeline

```
Session Events → Event Serializer → Compressor (zstd) → Disk Writer
                                               │
                                        ┌──────┴──────┐
                                        │ ring buffer  │
                                        │ (64 MB)      │
                                        └─────────────┘
```

- Events are timestamped with microsecond precision
- Disk writes are batched (100ms flush interval) to reduce I/O
- Encryption at rest using AES-256-GCM with per-session key

---

## 10. Multi-Monitor & Remote Printing

### 10.1 Multi-Monitor

- **RDP**: Native `MonitorLayout PDU` — engine exposes monitor rects to UI
  which renders N `CustomPainter` canvases in a scrollable `Row`
- **VNC**: `ExtendedDesktopSize` pseudo-encoding with server-side layout
- **UI**: Draggable monitor arrangement widget; snap-to-grid alignment

### 10.2 Remote Printing (RDP)

```
RDP Print Channel (MS-RDPEPC)
       │
       ▼
Engine receives XPS/EMF print job
       │
       ▼
Convert to PDF (via `printpdf` crate)
       │
       ▼
Bridge → Flutter → Platform print dialog
       │
       ▼
Native print spooler
```

---

## 11. FFI / JNI Data Types

### Shared Types (Rust side)

```rust
#[repr(C)]
pub struct CSessionConfig {
    pub host: *const c_char,
    pub port: u16,
    pub protocol: u8,       // 0=SSH, 1=VNC, 2=RDP
    pub compress_level: u8,
    pub record_session: bool,
}

#[repr(C)]
pub struct CTerminalFrame {
    pub data: *const u8,
    pub len: usize,
    pub rows: u16,
    pub cols: u16,
}
```

### Shared Types (Dart side)

```dart
final class TerminalFrame extends Struct {
  @Uint8()
  external Pointer<Uint8> data;
  @Size()
  external int len;
  @Uint16()
  external int rows;
  @Uint16()
  external int cols;
}
```

---

## 12. Deployment Plan

### 12.1 Distribution Matrix

| Platform | Format | Store | CI Runner |
|----------|--------|-------|-----------|
| Windows 10+ | MSI (WiX) + MSIX | winget, Microsoft Store | `windows-latest` |
| Ubuntu 22.04+ | DEB + Snap | PPA, Snap Store | `ubuntu-latest` |
| Android 10+ | APK + AAB | Google Play, F-Droid | `ubuntu-latest` (Android SDK) |

### 12.2 CI/CD Pipeline

```yaml
# .github/workflows/build.yml
name: Build & Release
on:
  push:
    tags: ['v*']
  pull_request:
    branches: [main]

jobs:
  build-engine:
    strategy:
      matrix:
        target: [x86_64-pc-windows-msvc, x86_64-unknown-linux-gnu, aarch64-linux-android]
    steps:
      - uses: actions/checkout@v4
      - uses: dtolnay/rust-toolchain@stable
        with:
          targets: ${{ matrix.target }}
      - run: cargo build --release --target ${{ matrix.target }}
      - uses: actions/upload-artifact@v4
        with:
          name: engine-${{ matrix.target }}
          path: target/${{ matrix.target }}/release/*

  build-ui:
    needs: build-engine
    strategy:
      matrix:
        platform: [windows, linux, android]
    steps:
      - uses: subosito/flutter-action@v2
      - run: flutter build ${{ matrix.platform == 'linux' && 'linux' || matrix.platform == 'windows' && 'windows' || 'apk' }} --release

  package:
    needs: build-ui
    steps:
      - run: wix build installer.wxs       # Windows MSI
      - run: dpkg-deb --build bluessh       # Linux DEB
      - run: flutter build appbundle        # Android AAB

  release:
    needs: package
    if: startsWith(github.ref, 'refs/tags/v')
    steps:
      - uses: softprops/action-gh-release@v1
        with:
          files: |
            dist/*.msi
            dist/*.deb
            dist/*.apk
            dist/*.aab
```

### 12.3 Self-Update Mechanism

```
┌─────────────────────────────────────────────┐
│             Auto-Update Flow                 │
│                                             │
│  1. UI polls /api/v1/releases/latest        │
│  2. Compare semver against current          │
│  3. Download delta (binary diff) or full    │
│  4. Verify Ed25519 signature of artifact    │
│  5. Stage update in temp directory          │
│  6. Prompt user to restart                  │
│  7. Replace binary, verify checksum         │
│  8. Restart application                     │
└─────────────────────────────────────────────┘
```

- **Delta updates**: Uses `bsdiff` for binary patches (typically 2–10% of full size)
- **Signature verification**: Ed25519 public key embedded in binary at build time
- **Rollback**: Previous binary retained for one update cycle; auto-rollback if new binary fails health check

### 12.4 Security Hardening

| Measure | Implementation |
|---------|---------------|
| ASLR | Enabled by default (Rust + Flutter) |
| DEP/NX | `/NXCOMPAT` on Windows; `-z noexecstack` on Linux |
| Stack canaries | Rust default; `-fstack-protector-strong` for C bridge |
| RELRO | Full RELRO on Linux (`-Wl,-z,relro,-z,now`) |
| Code signing | Authenticode (Windows), codesign (macOS future), apksigner (Android) |
| Sandboxing | AppArmor profile on Linux; Android app sandbox |
| Secrets in memory | `mlock` for key material; zeroize on drop (`zeroize` crate) |
| Network | Certificate pinning for update server; DNS-over-HTTPS |
| Audit | `cargo-audit` in CI; `cargo-deny` for license/vuln checks |

---

## 13. File Transfer (SFTP) — Parallel Transfer Strategy

```
                    ┌─────────────┐
                    │  Transfer   │
                    │  Scheduler  │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
         ┌─────────┐ ┌─────────┐ ┌─────────┐
         │Worker 1 │ │Worker 2 │ │Worker N │  (N = min(8, cpu_cores))
         │chunk 0  │ │chunk 1  │ │chunk N  │
         └────┬────┘ └────┬────┘ └────┬────┘
              │            │            │
              └────────────┼────────────┘
                           ▼
                    ┌─────────────┐
                    │  Merger &   │
                    │  Checksum   │
                    └─────────────┘
```

- Large files are split into N chunks processed in parallel over separate SFTP channels
- Chunk size adapts: starts at 64KB, adjusts based on throughput
- Pause/resume via chunk manifest (stored locally as `.transfer.json`)
- Integrity: SHA-256 computed per-chunk during transfer, whole-file verification on completion

---

## 14. Clipboard Sharing

```
┌─────────────┐         ┌─────────────┐
│ Local OS    │ ◀─────▶ │ Remote OS   │
│ Clipboard   │         │ Clipboard   │
└──────┬──────┘         └──────┬──────┘
       │                       │
       ▼                       ▼
  ┌─────────┐            ┌─────────┐
  │Platform │            │Protocol │
  │Bridge   │            │Channel  │
  │(FFI)    │            │(SSH/RDP)│
  └────┬────┘            └────┬────┘
       │                       │
       └───────────┬───────────┘
                   ▼
            ┌─────────────┐
            │  Clipboard  │
            │  Router     │
            └─────────────┘
```

- **SSH**: OSC 52 (Operating System Command) for text; custom SFTP channel for files
- **RDP**: CLIPRDR virtual channel (MS-RDPECLIP) — text, RTF, HTML, file list
- **VNC**: `ClientCutText` / `ServerCutText` messages
- **Local bridge**: Platform APIs — `Win32 Clipboard`, `X11 xclip`/`wl-clipboard`, `Android ClipboardManager`
- **Throttle**: Debounced at 200ms to prevent feedback loops

---

## 15. Summary of Libraries & Protocols per Feature

| Feature | Protocol | Rust Library | Flutter Widget |
|---------|----------|-------------|----------------|
| Terminal | SSH-2 | `russh` | `xterm.dart` |
| File Transfer | SFTP v3 | Custom (over `russh`) | `file_list.dart` |
| Remote Desktop (Linux/Win) | RFB 3.8 | Custom `rfb` crate | `vnc_canvas.dart` |
| Remote Desktop (Windows) | RDP 10.x | `ironrdp` | `rdp_canvas.dart` |
| Clipboard | OSC52 / CLIPRDR | Custom | Platform bridge |
| Recording | asciinema v2 + binary | Custom | `recording_service.dart` |
| Compression | zstd / zlib | `zstd` + `flate2` | N/A (engine) |
| TLS | TLS 1.3 | `rustls` | N/A (engine) |
| Auth Keys | Ed25519/ECDSA | `ring` | Key store UI |
| MFA | TOTP/FIDO2 | Custom + `libfido2` | TOTP input widget |
| Updates | HTTPS + bsdiff | `reqwest` + `bsdiff` | `update_service.dart` |
