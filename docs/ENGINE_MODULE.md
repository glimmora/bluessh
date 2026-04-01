# BlueSSH — Rust Core Engine Specification

## Module Responsibilities

### `lib.rs` — Public Entry Points

Exposes the C-ABI and JNI interface consumed by the Flutter bridge layer.
All public functions are `#[no_mangle] pub extern "C"` (desktop) or
`#[jni_fn]` (Android).

#### C-ABI Functions (Windows/Linux)

```rust
// session lifecycle
pub extern "C" fn engine_connect(config: *const CSessionConfig) -> SessionId;
pub extern "C" fn engine_disconnect(session_id: SessionId) -> i32;
pub extern "C" fn engine_auth_password(session_id: SessionId, pw: *const c_char) -> i32;
pub extern "C" fn engine_auth_key(session_id: SessionId, key_path: *const c_char) -> i32;
pub extern "C" fn engine_auth_mfa(session_id: SessionId, code: *const c_char) -> i32;

// terminal I/O
pub extern "C" fn engine_write(session_id: SessionId, data: *const u8, len: usize) -> i32;
pub extern "C" fn engine_read_poll(session_id: SessionId, callback: FrameCallback) -> i32;
pub extern "C" fn engine_resize(session_id: SessionId, cols: u16, rows: u16) -> i32;

// sftp
pub extern "C" fn engine_sftp_list(session_id: SessionId, path: *const c_char, callback: FileListCallback) -> i32;
pub extern "C" fn engine_sftp_upload(session_id: SessionId, src: *const c_char, dst: *const c_char, callback: ProgressCallback) -> i32;
pub extern "C" fn engine_sftp_download(session_id: SessionId, src: *const c_char, dst: *const c_char, callback: ProgressCallback) -> i32;

// clipboard
pub extern "C" fn engine_clipboard_set(session_id: SessionId, data: *const u8, len: usize) -> i32;
pub extern "C" fn engine_clipboard_get(session_id: SessionId, callback: ClipboardCallback) -> i32;

// recording
pub extern "C" fn engine_recording_start(session_id: SessionId, path: *const c_char) -> i32;
pub extern "C" fn engine_recording_stop(session_id: SessionId) -> i32;

// lifecycle
pub extern "C" fn engine_init() -> i32;
pub extern "C" fn engine_shutdown() -> i32;
```

#### JNI Functions (Android)

Identical semantics, wrapped via `jni_fn` proc-macro with `JNIEnv` parameter.

---

### `bridge/` — Marshalling Layer

Converts between C-ABI/JNI types and Rust domain types.

**Key type**: `BridgeState` — global singleton holding:
- `HashMap<SessionId, SessionHandle>` — active sessions
- `tokio::runtime::Handle` — runtime reference for spawning async tasks
- `Arc<EngineConfig>` — shared configuration

**Message framing**: All data crossing the bridge uses the binary frame format:
```
[magic: u16][msg_id: u32][length: u32][payload: [u8; length]]
```

---

### `session/` — Session Manager

**State Machine**:
```
Connecting → Authenticating → Connected → [Active | Idle] → Disconnecting → Disconnected
                                      ↓                         ↑
                                   [Recovering] ───────────────┘
```

**Event Bus**: `tokio::sync::broadcast` channel with typed events:
```rust
pub enum SessionEvent {
    Connected,
    Disconnected(DisconnectReason),
    TerminalData(Vec<u8>),
    TerminalResize(u16, u16),
    SftpProgress { file_id: u64, bytes: u64, total: u64 },
    SftpComplete { file_id: u64 },
    ClipboardUpdate(Vec<u8>),
    AuthChallenge(AuthMethod),
    RecordingFrame(Vec<u8>),
    Error(SessionError),
}
```

---

### `ssh/` — SSH Protocol Handler

Built on `russh` 0.40+ with the following customizations:

- **Channel multiplexing**: 1 shell + N exec channels + 1 SFTP subsystem channel
- **X11 forwarding**: Optional X11 channel for GUI applications on remote
- **Agent forwarding**: SSH agent channel when requested
- **Port forwarding**: Local (-L), remote (-R), dynamic (-D) SOCKS proxy

```rust
pub struct SshSession {
    client: russh::client::Handle,
    shell_channel: Option<ChannelId>,
    sftp_channel: Option<ChannelId>,
    forward_channels: HashMap<u32, ForwardChannel>,
}
```

---

### `sftp/` — SFTP Implementation

Implements SFTP v3 (draft-ietf-secsh-filexfer-02) over the SSH subsystem channel.

**Parallel transfer architecture**:
- `TransferScheduler` divides files into chunks
- Each chunk runs on its own SSH channel (up to `max_workers` = 8)
- `ChunkManifest` enables resume — persists `.transfer.json` alongside target file
- Checksums computed per-chunk with SHA-256; full-file verification on completion

---

### `vnc/` — VNC/RFB Client

Custom RFB 3.8 implementation supporting:

| Encoding | Description | Use Case |
|----------|-------------|----------|
| Raw | Uncompressed pixel data | High-bandwidth local networks |
| Hextile | Tile-based with sub-encodings | Moderate bandwidth |
| ZRLE | Zlib-compressed run-length | Low bandwidth |
| Tight | zlib/JPEG hybrid | Very low bandwidth |
| Cursor | Remote cursor shape | All scenarios |
| ExtendedDesktopSize | Multi-monitor layout | Multi-monitor setups |

**Frame buffer**: Shared `Arc<RwLock<Image>>` backed by `image` crate.
Rendering via Flutter `CustomPainter` that reads from the shared buffer through the bridge.

---

### `rdp/` — RDP Client

Wraps `ironrdp` 0.5+ with integration for:

- **Graphics pipeline**: RFX, NSCodec, Progressive, Planar
- **Virtual channels**: CLIPRDR (clipboard), RDPSND (audio), RDPDR (device redirection including printing)
- **Multi-monitor**: Display Update PDU with per-monitor geometry
- **Gateway**: RD Gateway (HTTP/HTTPS) for tunneling through firewalls

---

### `clipboard/` — Clipboard Router

Bridges local OS clipboard with remote session clipboard:

```
Local OS API  ←→  ClipboardRouter  ←→  Protocol Handler
   │                    │                     │
   ├─ Win32             ├─ Format negotiation  ├─ SSH: OSC 52
   ├─ X11/Wayland       ├─ Throttle (200ms)    ├─ RDP: CLIPRDR
   └─ Android           └─ Size limits (16MB)  └─ VNC: CutText
```

---

### `recording/` — Session Recorder

**Formats**:
1. **Asciinema v2** (terminal): JSON lines with timing
2. **Binary recording** (VNC/RDP): Frame-by-frame with timestamps
3. **Audit log** (all): Structured JSON lines for compliance

**Pipeline**: Event → Serializer → zstd Compressor → Ring Buffer (64MB) → Disk Writer (100ms flush)

**Encryption**: AES-256-GCM with per-session key derived via HKDF-SHA256.

---

### `compression/` — Adaptive Compression

```rust
pub enum CompressionLevel {
    None,       // >50 Mbps local
    ZstdLow,    // 1-50 Mbps, level 1-3
    ZstdMed,    // 0.5-1 Mbps, level 4-6
    ZstdHigh,   // <0.5 Mbps, level 7-19
    Zlib,       // Fallback for legacy servers
}

pub struct AdaptiveCompressor {
    current: CompressionLevel,
    estimator: BandwidthEstimator,
    zstd_encoder: zstd::stream::Encoder<'static>,
    zlib_encoder: flate2::Compress,
}
```

Adaptation trigger: every 5 seconds, `BandwidthEstimator` updates and
`select_level()` may transition the compressor to a new level.

---

### `keepalive/` — Heartbeat Manager

Per-protocol keepalive strategies:

| Protocol | Mechanism | Interval | Misses Before Degraded |
|----------|-----------|----------|----------------------|
| SSH | `keepalive@openssh.com` global request | 30s | 3 |
| VNC | Incremental `FramebufferUpdateRequest` | 15s | 3 |
| RDP | Keep-Alive PDU (MS-RDPBCGR §3.3.5.4) | 30s | 3 |
| Engine | Application heartbeat over bridge | 10s | 2 |

State transitions follow the state machine in ARCHITECTURE.md §7.1.

---

### `auth/` — Authentication Engine

**Key store abstraction**:
```rust
pub trait KeyStore: Send + Sync {
    fn store_key(&self, alias: &str, key: &PrivateKey) -> Result<()>;
    fn load_key(&self, alias: &str) -> Result<PrivateKey>;
    fn delete_key(&self, alias: &str) -> Result<()>;
    fn list_keys(&self) -> Result<Vec<KeyInfo>>;
}
```

Implementations:
- `WindowsKeyStore`: DPAPI + Windows Credential Locker
- `LinuxKeyStore`: GNOME Keyring (via D-Bus secret service API)
- `AndroidKeyStore`: Android Keystore System (via JNI)

**MFA providers**:
- `TotpProvider`: RFC 6238 TOTP with encrypted secret storage
- `Fido2Provider`: CTAP2 via `libfido2` FFI (desktop) or Android FIDO2 API

---

### `fir/` — Self-Update (Firmware-In-Update metaphor)

**Update protocol**:
1. `GET /api/v1/releases/latest` → JSON with `{version, url, signature, checksum, patch_url}`
2. Verify Ed25519 signature against embedded public key
3. Download bsdiff patch (typically 2-10% of full binary)
4. Apply patch: `bspatch(old_binary, new_binary, patch)`
5. Verify SHA-256 checksum of result
6. Stage in temp directory; prompt user for restart
7. On restart: swap binaries, health check, auto-rollback on failure

---

## Concurrency Model

```
┌────────────────────────────────────────────────┐
│                  Tokio Runtime                   │
│                  (multi-thread)                  │
│                                                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐        │
│  │ Session 1│ │ Session 2│ │ Session N│        │
│  │ (own     │ │ (own     │ │ (own     │        │
│  │  task    │ │  task    │ │  task    │        │
│  │  group)  │ │  group)  │ │  group)  │        │
│  └──────────┘ └──────────┘ └──────────┘        │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │         Bridge I/O Task Pool               │ │
│  │   (reads from FFI/JNI, dispatches events)  │ │
│  └────────────────────────────────────────────┘ │
│                                                  │
│  ┌────────────────────────────────────────────┐ │
│  │         Recording Writer Pool              │ │
│  │   (background disk writes)                 │ │
│  └────────────────────────────────────────────┘ │
└────────────────────────────────────────────────┘
```

Each session gets its own `JoinSet` of tasks:
- Protocol I/O task (reads/writes to remote server)
- Bridge writer task (sends frames to UI)
- Keepalive task (sends pings, monitors health)
- Recording task (writes frames to disk)

Sessions are fully independent and can operate concurrently without blocking each other.

---

## Error Handling Strategy

```rust
pub enum EngineError {
    Connection(ConnectionError),
    Auth(AuthError),
    Protocol(ProtocolError),
    Io(std::io::Error),
    Bridge(BridgeError),
    Internal(String),
}

// All errors convert to C-compatible error codes for the bridge
impl From<EngineError> for CErrorCode {
    fn from(e: EngineError) -> Self {
        match e {
            EngineError::Connection(_) => 1001,
            EngineError::Auth(_) => 1002,
            EngineError::Protocol(_) => 1003,
            EngineError::Io(_) => 1004,
            EngineError::Bridge(_) => 1005,
            EngineError::Internal(_) => 1099,
        }
    }
}
```

User-facing errors are translated on the Flutter side with localized messages.
