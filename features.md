# BlueSSH — Feature Specification

## 1. Protocol Support

- **SSH-2** — Full terminal/shell access via PTY with `xterm-256color` terminal emulation, built on the `russh` Rust library.
- **SFTP v3** — File transfer over SSH subsystem; shell-based fallback (`ls`, `cp`, `rm`, `mv`) when SFTP is unavailable.
- **VNC (RFB 3.8)** — Graphical remote desktop with frame rendering via `CustomPainter`.
- **RDP (10.x)** — Windows remote desktop support, sharing the VNC viewer infrastructure.

## 2. Authentication Methods

- **Password authentication** — Plaintext password auth with automatic zeroization after use.
- **SSH key file** — Authenticate using an existing private key file on disk. Loads key via `russh::keys::load_secret_key`, authenticates with `authenticate_publickey`.
- **SSH key data (Android)** — Raw key bytes written to a temporary file with `chmod 600`, authenticated via `engine_auth_key`, then cleaned up.
- **MFA / TOTP** — Time-based one-time password generation from a base32 shared secret (SHA1, 6-digit code, 30-second period).
- **MFA secret storage** — TOTP shared secrets stored encrypted in the host profile via secure storage.

## 3. SSH Key Generation & Management

- **Ed25519 key generation** — Generates a private key and `.pub` public key file, written to disk with `0600` permissions.
- **ECDSA / RSA options** — UI exposes ECDSA and RSA-4096 options (engine-level support planned).
- **Key import** — File picker to import existing key files; auto-detects type (ed25519 / ecdsa / rsa) from file content and computes fingerprint.
- **Key management UI** — List, generate, import, and delete keys with fingerprint display in the Settings screen.

## 4. Session Recording & Playback

- **Terminal recording** — Saves terminal sessions to `.cast` files in asciinema v2 JSON format. Writes header with version/width/height/timestamp/env, then timestamped output lines `[elapsed, "o", "data"]`. Writes header with version/width/height/timestamp/env, then timestamped output lines `[elapsed, "o", "data"]`.
- **VNC / RDP recording** — Saves graphical sessions to `.vnc-rec` / `.rdp-rec` files.
- **Recording playback** — Parses asciinema v2 JSON; play / pause / stop controls with line-by-line playback at 50 ms intervals.
- **Record by default** — Global setting to auto-start recording for all new sessions.
- **Per-host recording toggle** — Individual toggle per host profile.

## 5. Port Forwarding

- **Local forwarding** — Remote-to-local port tunneling.
- **Remote forwarding** — Local-to-remote port tunneling.
- **Dynamic (SOCKS5)** — Dynamic proxy forwarding via SOCKS5 protocol.
- **Per-host forwarding rules** — Multiple rules per host with individual enable/disable toggles.
- **Configuration UI** — Add, remove, and toggle forwarding rules with a type selector in the Forwarding screen.

## 6. Clipboard Synchronization

- **Remote-to-local sync** — Copies remote clipboard content to the local device clipboard automatically.
- **Local-to-remote paste** — Pushes local clipboard content into the remote session via Ctrl+Shift+V or toolbar button.
- **VNC / RDP clipboard** — JNI bridge for bidirectional clipboard in graphical sessions.
- **Clipboard toggle** — Global and per-session enable/disable for clipboard synchronization.

## 7. Terminal Customization

- **xterm emulator** — Full xterm 4.0 emulation with `KeyEvent` support and a 10,000-line scrollback buffer.
- **Terminal theme** — Catppuccin-inspired color scheme covering cursor, selection, ANSI colors 0–15, and search highlights.
- **Font size** — Adjustable from 10 px to 24 px via a slider in Settings.
- **Timestamps** — Optional timestamp display on terminal output lines.
- **Background opacity** — Semi-transparent terminal background (95% opacity).
- **Search in terminal** — Ctrl+F search bar with next / previous navigation and match count.
- **Keyboard shortcuts** — Ctrl+Shift+C (copy), Ctrl+Shift+V (paste), Ctrl+F (search), Esc (close search bar).

## 8. Multi-Tab Terminal

- **Tab management** — Create, switch, and close tabs; each tab hosts an independent SSH session.
- **Tab keyboard shortcuts** — Ctrl+T (new tab), Ctrl+W (close tab), Ctrl+Tab / Ctrl+Shift+Tab (cycle tabs).
- **Tab bar UI** — Horizontal scrollable list of `InputChip` widgets with active indicator and close buttons.

## 9. Host Profile Management

- **CRUD operations** — Add, edit, and delete host profiles via a bottom sheet form.
- **Profile fields** — Name, host, port, protocol, username, password, key path, key data, passphrase, compression level, MFA secret, tags, environment variables, working directory, jump host settings, port forwarding rules, and agent forwarding.
- **Search and filter** — Filter saved hosts by name, hostname, username, or protocol.
- **Usage tracking** — Automatically records `lastUsed` timestamp and `connectionCount` on each successful connection.
- **Tags** — User-defined tags for organizing hosts.
- **Jump / bastion host** — Configure an intermediary SSH host to proxy the connection.
- **Environment variables** — Set custom environment variables for the remote shell session.
- **Working directory** — Specify a preferred directory to open after login.
- **Agent forwarding** — Toggle SSH agent forwarding per host.

## 10. Credential Storage

- **Encrypted secure storage** — Passwords, key data, passphrases, MFA secrets, and jump host passwords stored using `flutter_secure_storage`.
- **Android** — Uses Android `EncryptedSharedPreferences`.
- **Linux** — Uses `libsecret` (GNOME Keyring).
- **Windows** — Uses Data Protection API (DPAPI).
- **Profile / credential split** — Non-sensitive data in `SharedPreferences`; sensitive data in secure storage; merged on load.

## 11. Connection Keepalive & Auto-Reconnect

- **Keepalive timer** — Periodic null-byte writes at a configurable interval (default 30 s, adjustable 10–120 s).
- **Keepalive failure events** — Emits a `keepalive_failed` event, displayed as "Connection unstable" in the terminal.
- **Auto-reconnect** — Automatic reconnection with exponential backoff (1 s, 2 s, 4 s, 8 s, 16 s, 32 s).
- **Max reconnect attempts** — Configurable from 1 to 10 attempts via a slider in Settings.
- **Reconnect events** — Terminal shows "Reconnected (attempt N)" or "Connection lost" messages.
- **Connection timeout** — 30-second timeout on connection attempts to prevent indefinite hangs.

## 12. Adaptive Compression

- **Four compression levels:**
  - **None** — No compression, best for LAN (> 50 Mbps).
  - **Low** — zstd levels 1–3, balanced for 1–50 Mbps links.
  - **Medium** — zstd levels 4–6, suitable for 0.5–1 Mbps.
  - **High** — zstd levels 7–19, for constrained links (< 0.5 Mbps).
- **Per-session adjustment** — Change compression level during an active session via a radio dialog.
- **Default compression** — Global default level for new connections, configured in Settings.

## 13. Known Hosts Verification

- **Host key storage** — `HashMap` keyed by `[host]:port`, persisted to `known_hosts.json`.
- **Key verification** — Returns match / no-entry / mismatch to detect MITM attacks.
- **Key acceptance** — Called after user approves a new host key.
- **Host key events** — Emits key type and SHA-256 fingerprint for UI display. Server key accepted by default (russh `check_server_key` returns `Ok(true)`); known_hosts module available for future strict verification. Server key accepted by default (russh `check_server_key` returns `Ok(true)`); known_hosts module available for future strict verification.

## 14. SFTP File Manager

- **Directory listing** — Lists files with name, size, permissions, modified time, and owner.
- **Navigation** — Path bar, up / home buttons, and directory tap for browsing the remote filesystem.
- **Upload** — File picker for multi-file selection with a progress dialog.
- **Download** — Downloads to the app documents directory with a progress dialog.
- **Create directory** — Remote `mkdir -p` via the engine.
- **Rename** — Rename remote files and directories.
- **Delete** — Multi-select delete with a confirmation dialog.
- **Transfer progress** — Real-time progress bar showing speed (KB/s, MB/s) and percentage.
- **File type icons** — Context-aware icons by extension (py, js, sh, txt, images, archives, JSON, YAML).
- **Permissions display** — Unix-style `drwxr-xr--` permission format.

## 15. Remote Desktop Viewer (VNC / RDP)

- **Frame rendering** — Decodes frame data to `ui.Image` and renders at native resolution via `CustomPainter`.
- **Multi-monitor** — Detects and renders multiple monitors with a monitor selector popup.
- **Pinch-to-zoom** — Scale from 0.25x to 4.0x with panning support.
- **Fit to screen** — Auto-calculates the optimal scale to fit the monitor in the viewport.
- **Reset zoom** — Returns to 1.0x scale with zero pan offset.
- **Keyboard input** — X11 keysym mapping for F1–F24, numpad, modifiers, navigation, and arrow keys.
- **Mouse / touch input** — Left click, right click (long-press), double-click, and secondary tap.
- **Fullscreen mode** — Edge-to-edge system UI mode (preserves Android navigation bar).
- **Performance stats** — FPS counter and bytes-received display in the AppBar.
- **Recording** — Same recording infrastructure as terminal sessions.
- **Toolbar toggle** — FAB button to show/hide the AppBar toolbar.
- **Connection status** — Green/red indicator icon for connected / disconnected state.
- **Disconnected overlay** — Red "Disconnected" text when connection is lost; "Waiting for remote desktop..." during initial connection.

## 16. Theming

- **Dark theme** — Material Design 3 with color seed `#4FC3F7`, scaffold `#0D1117`, cards `#21262D` with `#30363D` borders.
- **Light theme** — Material Design 3 with color seed `#0969DA`, scaffold `#F6F8FA`, white cards with `#D0D7DE` borders.
- **Theme mode setting** — Light / Dark / Auto (system) segmented button in Settings.
- **Edge-to-edge** — Transparent status and navigation bars on Android 15+.

## 17. Android-Specific Features

- **Foreground service** — Keeps the process alive during active sessions with a persistent notification ("Remote session active") using `FOREGROUND_SERVICE_TYPE_DATA_SYNC`.
- **Notification channel** — `bluessh_session` channel at `IMPORTANCE_LOW` with no badge.
- **START_STICKY** — Service automatically restarts if killed by the OS.
- **Runtime permissions** — Requests `POST_NOTIFICATIONS` (Android 13+) and storage permissions for SFTP file operations.
- **ABI splits** — Generates per-architecture APKs: `armeabi-v7a`, `arm64-v8a`, `x86`, `x86_64`, plus a universal APK.
- **Version code overrides** — Each ABI split receives a unique version code for Google Play distribution.
- **ProGuard / R8** — Release builds are minified and resource-shrunk with keep rules for JNI bridge classes.
- **JNI bridge** — Kotlin `EngineBridge` calls Rust via `System.loadLibrary("bluessh")` over `MethodChannel("com.bluessh/engine")`.

## 18. Desktop FFI Bridge

- **`dart:ffi` bindings** — Direct C-ABI calls to `libbluessh.so` (Linux), `bluessh.dll` (Windows), `libbluessh.dylib` (macOS).
- **FFI structs** — `CSessionConfig` and `CTerminalFrame` matching Rust `#[repr(C)]` layouts.
- **Function bindings** — 12 native functions: `engine_init`, `engine_shutdown`, `engine_connect`, `engine_disconnect`, `engine_write`, `engine_resize`, `engine_auth_password`, `engine_auth_key`, `engine_auth_mfa`, `engine_recording_start`, `engine_recording_stop`, `engine_key_generate`.
- **State stream** — Broadcast `Stream<FfiSessionState>` for UI consumption.

## 19. Rust Engine Internals

- **Tokio async runtime** — Multi-threaded runtime with 2 worker threads named `bluessh-worker`.
- **Global engine state** — Process-wide singleton (`OnceLock<RwLock<EngineState>>`) holding a `HashMap<SessionId, SessionHandle>`.
- **Session ID management** — Monotonic `u64` counter starting at 1 with overflow protection.
- **SSH handshake** — TCP connect + SSH handshake with configurable timeout; PTY request with `xterm-256color`.
- **Bidirectional I/O** — `tokio::select!` loop reading server data (`ChannelMsg::Data`, `ExtendedData`, `Eof`, `Close`) and writing commands from FFI.
- **Channel bridging** — Bounded `mpsc` channels bridging FFI and Tokio via spawned forwarder threads.
- **Password zeroization** — `zeroize` crate ensures credentials are wiped from memory after use.
- **Structured logging** — `tracing` + `tracing-subscriber` with JSON-formatted output at `bluessh=info` level.
- **Dual C-ABI / JNI interface** — Same engine serves desktop (C-ABI FFI) and Android (JNI exports).
- **Engine tests** — 25+ tests covering null safety, idempotent initialization, session CRUD, authentication, SFTP, TOTP, key generation, and type values.

## 20. Application Update Service

- **Update checker** — HTTP GET to `https://api.bluessh.io/v1/releases/latest` with a 10-second timeout.
- **Semantic versioning** — Compares `major.minor.patch` version strings to determine if an update is available.
- **Update metadata** — `UpdateInfo` model containing version, release date, download URLs, SHA-256 checksums, digital signature, release notes, and file sizes.

## 21. State Management

- **Riverpod** — `ProviderScope` at the app root with typed providers.
- **Session providers** — `sessionServiceProvider`, `activeSessionsProvider`, `transferProgressProvider` for reactive state.
- **ChangeNotifier** — `TabManager` extends `ChangeNotifier` for tab state changes via `ListenableBuilder`.

## 22. Build & Distribution

- **Cross-platform build scripts** — `build_ubuntu.sh` (Linux tar.gz + .deb), `build_android.sh` (per-ABI APKs), `build_windows.bat` / `build_windows.sh` (Windows DLL cross-compile).
- **Debian packaging** — `.deb` package with control metadata in `installer/linux/control`.
- **Windows installer** — WiX-based MSI definition in `installer/windows/product.wxs`.
- **Build watchdog** — Auto-monitors build scripts for file changes; detects 34 error patterns; applies predefined fixes; supports daemon mode.
- **LTO release profile** — `Cargo.toml` release profile with `lto = true`, `codegen-units = 1`, `strip = true`, `opt-level = "z"`, `panic = "abort"`.

## 23. Dependencies

| Package | Purpose |
|---------|---------|
| `xterm ^4.0.0` | Terminal emulator |
| `file_picker ^8.0.0` | File selection for upload and key import |
| `path_provider ^2.1.0` | App documents directory access |
| `shared_preferences ^2.2.0` | Settings persistence |
| `flutter_secure_storage ^9.2.2` | Encrypted credential storage |
| `riverpod ^2.5.0` / `flutter_riverpod ^2.5.0` | Reactive state management |
| `http ^1.2.0` | HTTP client for update checker |
| `ffi ^2.1.0` | Desktop native bridge |
| `json_annotation ^4.9.0` | JSON serialization |
| `material_design_icons_flutter ^7.0.0` | Extended icon set |
| `fl_chart ^0.68.0` | Charts and statistics |
| `permission_handler ^11.3.1` | Android runtime permissions |
