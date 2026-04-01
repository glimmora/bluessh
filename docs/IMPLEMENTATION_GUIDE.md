# BlueSSH — Feature Implementation Guide (Features 1–10)

This guide provides step-by-step instructions for implementing the ten highest-priority
features across Linux, Windows, and Android. Each section includes architecture decisions,
platform-specific code, and verification steps.

---

## Table of Contents

1. [Encrypted Credential Storage](#1-encrypted-credential-storage)
2. [Implement Actual SSH Protocol](#2-implement-actual-ssh-protocol)
3. [SSH Host Key Verification](#3-ssh-host-key-verification)
4. [MFA Secret Encryption](#4-mfa-secret-encryption)
5. [Functional SFTP File Upload](#5-functional-sftp-file-upload)
6. [Multi-Tab Terminal](#6-multi-tab-terminal)
7. [Port Forwarding / Tunneling](#7-port-forwarding--tunneling)
8. [SSH Jump Host / Proxy](#8-ssh-jump-host--proxy)
9. [Real SSH Key Generation](#9-real-ssh-key-generation)
10. [SSH Agent Forwarding](#10-ssh-agent-forwarding)

---

## 1. Encrypted Credential Storage

### Problem

`home_screen.dart:43-58` stores host profiles (including passwords) as JSON strings in
`SharedPreferences`, which writes them to disk in plaintext. On Android this is
`/data/data/com.bluessh.bluessh/shared_prefs/`; on Linux it is `~/.local/share/`.
Any app with file access or device backup can extract credentials.

The `toJson()` method in `host_profile.dart:225` intentionally excludes the `password`
and `keyData` fields, but `fromJson()` at line 244 cannot restore them — meaning
credentials are silently lost on app restart. This is the current (broken) design:
persist without the password, then wonder why reconnection fails.

### Architecture

```
┌──────────────────────────────────────────────────────────┐
│  Flutter UI                                              │
│  ┌────────────────────────────────────────────────────┐  │
│  │  HostProfile (in-memory, includes password)        │  │
│  └──────────────┬─────────────────────┬───────────────┘  │
│                 │                     │                  │
│     ┌───────────▼──────────┐  ┌──────▼───────────────┐  │
│     │  SecureCredential     │  │  SharedPreferences   │  │
│     │  Storage (password,   │  │  (name, host, port,  │  │
│     │  keyData, mfaSecret)  │  │  protocol, username) │  │
│     └───────────┬──────────┘  └──────▲───────────────┘  │
│                 │                     │                  │
└─────────────────┼─────────────────────┼──────────────────┘
                  │                     │
     ┌────────────▼─────────────────────┴───────────────┐
     │  Platform Secure Store                            │
     │  Linux:   libsecret (GNOME Keyring / KWallet)     │
     │  Windows: Windows Credential Manager (DPAPI)      │
     │  Android: Android Keystore + EncryptedSharedPreferences │
     └──────────────────────────────────────────────────┘
```

### Step 1: Add the dependency

Edit `ui/pubspec.yaml`, add under `dependencies:`:

```yaml
  flutter_secure_storage: ^9.2.2
```

Then run:

```bash
cd ui && flutter pub get
```

### Step 2: Create the credential service

Create a new file `ui/lib/services/credential_service.dart`:

```dart
/// Encrypted credential storage service.
///
/// Stores sensitive fields (passwords, key data, MFA secrets) in the
/// platform's secure enclave, while non-sensitive profile data remains
/// in SharedPreferences for fast loading.
library;

import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host_profile.dart';

/// Android-specific secure storage options.
///
/// EncryptedSharedPreferences uses Android's Jetpack Security library
/// to encrypt keys and values with a master key stored in the Keystore.
/// The `sharedPreferencesName` keeps encrypted data separate from the
/// app's normal preferences file.
const _androidOptions = AndroidOptions(
  encryptedSharedPreferences: true,
  sharedPreferencesName: 'bluessh_secure_prefs',
);

/// Linux-specific options — uses libsecret (GNOME Keyring).
const _linuxOptions = LinuxOptions();

/// Windows-specific options — uses Data Protection API (DPAPI).
const _windowsOptions = WindowsOptions();

class CredentialService {
  static CredentialService? _instance;

  final FlutterSecureStorage _storage;

  CredentialService._()
      : _storage = const FlutterSecureStorage(
          aOptions: _androidOptions,
          lOptions: _linuxOptions,
          wOptions: _windowsOptions,
        );

  /// Returns the singleton instance.
  factory CredentialService.instance() =>
      _instance ??= CredentialService._();

  /// Stores the sensitive fields of a [HostProfile] in secure storage.
  ///
  /// The key is the profile ID. Non-sensitive fields remain in
  /// SharedPreferences via the normal [HostProfile.toJson] path.
  Future<void> saveCredentials(HostProfile profile) async {
    final creds = <String, String>{};

    if (profile.password != null && profile.password!.isNotEmpty) {
      creds['password'] = profile.password!;
    }
    if (profile.keyData != null && profile.keyData!.isNotEmpty) {
      creds['keyData'] = profile.keyData!;
    }
    if (profile.passphrase != null && profile.passphrase!.isNotEmpty) {
      creds['passphrase'] = profile.passphrase!;
    }
    if (profile.mfaSecret != null && profile.mfaSecret!.isNotEmpty) {
      creds['mfaSecret'] = profile.mfaSecret!;
    }

    await _storage.write(
      key: 'creds_${profile.id}',
      value: jsonEncode(creds),
    );
  }

  /// Reads the sensitive fields back from secure storage.
  ///
  /// Returns an empty map if no credentials are stored for this ID.
  Future<Map<String, String>> loadCredentials(String profileId) async {
    final raw = await _storage.read(key: 'creds_$profileId');
    if (raw == null || raw.isEmpty) return {};

    try {
      final map = jsonDecode(raw) as Map<String, dynamic>;
      return map.cast<String, String>();
    } catch (_) {
      return {};
    }
  }

  /// Removes stored credentials for a deleted profile.
  Future<void> deleteCredentials(String profileId) async {
    await _storage.delete(key: 'creds_$profileId');
  }

  /// Writes credentials AND non-sensitive profile data to their
  /// respective stores in a single call.
  Future<void> saveProfile(HostProfile profile) async {
    final prefs = await SharedPreferences.getInstance();

    // Save non-sensitive fields to SharedPreferences
    final profiles = prefs.getStringList('host_profiles') ?? [];
    profiles.removeWhere((raw) {
      final existing = jsonDecode(raw) as Map<String, dynamic>;
      return existing['id'] == profile.id;
    });
    profiles.add(jsonEncode(profile.toJson()));
    await prefs.setStringList('host_profiles', profiles);

    // Save sensitive fields to secure storage
    await saveCredentials(profile);
  }

  /// Loads a complete [HostProfile] by merging SharedPreferences
  /// (non-sensitive) with secure storage (sensitive).
  Future<List<HostProfile>> loadAllProfiles() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getStringList('host_profiles') ?? [];

    final profiles = <HostProfile>[];
    for (final entry in raw) {
      try {
        final json = jsonDecode(entry) as Map<String, dynamic>;
        final creds = await loadCredentials(json['id'] as String);

        // Merge credentials back into the profile
        json['password'] = creds['password'];
        json['keyData'] = creds['keyData'];
        json['passphrase'] = creds['passphrase'];
        json['mfaSecret'] = creds['mfaSecret'];

        profiles.add(HostProfile.fromJson(json));
      } catch (_) {
        // Skip corrupted entries
      }
    }

    profiles.sort((a, b) => b.lastUsed.compareTo(a.lastUsed));
    return profiles;
  }

  /// Deletes both the profile metadata and its credentials.
  Future<void> deleteProfile(String profileId) async {
    final prefs = await SharedPreferences.getInstance();
    final profiles = prefs.getStringList('host_profiles') ?? [];
    profiles.removeWhere((raw) {
      final existing = jsonDecode(raw) as Map<String, dynamic>;
      return existing['id'] == profileId;
    });
    await prefs.setStringList('host_profiles', profiles);
    await deleteCredentials(profileId);
  }
}
```

### Step 3: Add `toJson` credential fields (opt-in)

The current `toJson()` in `host_profile.dart:225` excludes credentials. Add an optional
parameter so the credential service can request full serialization when needed:

```dart
/// Serializes to a JSON-compatible map.
///
/// When [includeCredentials] is true, sensitive fields are included.
/// Default is false for backward compatibility.
Map<String, dynamic> toJson({bool includeCredentials = false}) {
  final map = <String, dynamic>{
    'id': id,
    'name': name,
    'host': host,
    'port': port,
    'protocol': protocol.value,
    'username': username,
    'keyPath': keyPath,
    'compressionLevel': compressionLevel,
    'recordSession': recordSession,
    'useMfa': useMfa,
    'lastUsed': lastUsed.toIso8601String(),
    'connectionCount': connectionCount,
    'envVars': envVars,
    'workingDirectory': workingDirectory,
    'tags': tags,
  };

  if (includeCredentials) {
    map['password'] = password;
    map['keyData'] = keyData;
    map['passphrase'] = passphrase;
    map['mfaSecret'] = mfaSecret;
  }

  return map;
}
```

### Step 4: Update `home_screen.dart` to use `CredentialService`

Replace the `_loadProfiles()` and `_saveProfiles()` methods:

```dart
Future<void> _loadProfiles() async {
  final creds = CredentialService.instance();
  setState(() {
    _profiles = await creds.loadAllProfiles();
    _isLoading = false;
  });
}

Future<void> _saveProfile(HostProfile profile) async {
  await CredentialService.instance().saveProfile(profile);
}

Future<void> _deleteProfile(HostProfile profile) async {
  await CredentialService.instance().deleteProfile(profile.id);
  setState(() {
    _profiles.removeWhere((p) => p.id == profile.id);
  });
}
```

### Platform-specific notes

| Platform | Backend | Notes |
|----------|---------|-------|
| Linux | `libsecret` / GNOME Keyring | Requires `libsecret-1-dev` at build time. Falls back to file-based encryption if unavailable. |
| Windows | DPAPI | Credentials encrypted per-user. Works offline. Backup/restore moves encrypted blobs. |
| Android | EncryptedSharedPreferences | Uses Android Keystore master key. Requires API 23+. Data survives app updates but not factory reset. |

### Verification

1. Add a host with password `testpass123`.
2. Kill the app and relaunch.
3. Verify the host list shows the host AND the password field is non-null.
4. On Linux, check `secret-tool list service=bluessh` to confirm the entry exists.
5. On Android, verify `bluessh_secure_prefs.xml` does NOT appear in `shared_prefs/`.

---

## 2. Implement Actual SSH Protocol

### Problem

`engine/src/lib.rs` declares all FFI functions (`engine_connect`, `engine_write`,
`engine_auth_password`, etc.) but every function body is a stub that logs and returns 0.
The `russh 0.58` crate is listed in `Cargo.toml:17` but never imported. The `tokio`
runtime at line 14 is unused — there is no `#[tokio::main]`, no `Runtime`, and no
`.await` anywhere in the file.

### Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Dart UI (FFI / MethodChannel)                          │
│  engine_connect() ──► CSessionConfig pointer            │
│  engine_auth_password() ──► password C string           │
│  engine_write() ──► byte buffer                         │
└────────────────────┬────────────────────────────────────┘
                     │ FFI / JNI
┌────────────────────▼────────────────────────────────────┐
│  Rust Engine                                            │
│  ┌────────────────────────────────────────────────────┐ │
│  │  Tokio Runtime (global, initialized once)          │ │
│  │  ┌──────────────────────────────────────────────┐  │ │
│  │  │  SessionManager                              │  │ │
│  │  │  ┌──────────┐ ┌──────────┐ ┌──────────┐     │  │ │
│  │  │  │ Session 1│ │ Session 2│ │ Session N│     │  │ │
│  │  │  │ (russh)  │ │ (russh)  │ │ (russh)  │     │  │ │
│  │  │  └──────────┘ └──────────┘ └──────────┘     │  │ │
│  │  └──────────────────────────────────────────────┘  │ │
│  └────────────────────────────────────────────────────┘ │
│                         │                               │
│  Event Callbacks ───────┘ (channel, data, state)        │
└─────────────────────────────────────────────────────────┘
```

### Step 1: Add required dependencies to `Cargo.toml`

```toml
[dependencies]
tokio = { version = "1", features = ["full"] }
russh = "0.58"
russh-keys = "0.46"        # NEW — key parsing, generation
serde = { version = "1", features = ["derive"] }
serde_json = "1"
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter", "json"] }
zeroize = { version = "1", features = ["derive"] }
uuid = { version = "1", features = ["v4"] }
ssh-key = { version = "0.6", features = ["ed25519", "ecdsa", "rsa"] }  # NEW
```

### Step 2: Create the async runtime wrapper

Add a new module `engine/src/runtime.rs`:

```rust
//! Async runtime management for FFI entry points.
//!
//! The C-ABI functions called from Dart are synchronous. Internally,
//! each function spawns a task on a shared Tokio runtime and blocks
//! until the result is available.

use std::sync::OnceLock;
use tokio::runtime::Runtime;

/// Global Tokio runtime shared by all sessions.
static RUNTIME: OnceLock<Runtime> = OnceLock::new();

/// Returns a reference to the global runtime, initializing on first call.
pub fn runtime() -> &'static Runtime {
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .worker_threads(2)
            .thread_name("bluessh-worker")
            .build()
            .expect("Failed to create Tokio runtime")
    })
}

/// Blocks the current thread on an async future.
///
/// # Panics
///
/// Panics if called from within an existing Tokio runtime context.
/// This is safe because FFI entry points are always called from
/// Dart's platform thread, never from a Tokio worker.
pub fn block_on<F: std::future::Future>(fut: F) -> F::Output {
    runtime().block_on(fut)
}
```

### Step 3: Create the SSH session manager

Add `engine/src/ssh_session.rs`:

```rust
//! Per-session SSH connection handler using russh.

use russh::*;
use russh_keys::*;
use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{mpsc, RwLock};
use zeroize::Zeroize;

/// Events sent from the SSH session back to the FFI layer.
#[derive(Debug)]
pub enum SessionEvent {
    Connected,
    Authenticated,
    Data(Vec<u8>),
    Disconnected(String),
    Error(String),
    HostKeyReceived { key_type: String, fingerprint: String },
}

/// Configuration for a new SSH connection.
pub struct SshConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: Option<String>,
    pub key_path: Option<String>,
    pub key_data: Option<Vec<u8>>,
    pub passphrase: Option<String>,
}

/// Handle to an active SSH session.
pub struct SshSessionHandle {
    pub event_rx: mpsc::UnboundedReceiver<SessionEvent>,
    pub command_tx: mpsc::UnboundedSender<SessionCommand>,
}

/// Commands sent from the FFI layer to the SSH session.
#[derive(Debug)]
pub enum SessionCommand {
    Write(Vec<u8>),
    Resize { cols: u16, rows: u16 },
    Disconnect,
}

/// Client handler for russh.
struct ClientHandler {
    event_tx: mpsc::UnboundedSender<SessionEvent>,
}

impl russh::client::Handler for ClientHandler {
    type Error = anyhow::Error;

    async fn check_server_key(
        &mut self,
        server_public_key: &key::PublicKey,
    ) -> Result<bool, Self::Error> {
        let key_type = format!("{:?}", server_public_key.algorithm());
        let fingerprint = server_public_key
            .fingerprint(russh_keys::HashAlg::Sha256)
            .to_string();

        let _ = self.event_tx.send(SessionEvent::HostKeyReceived {
            key_type,
            fingerprint,
        });

        // Accept all keys for now — host key verification is Feature 3.
        Ok(true)
    }
}

/// Establishes an SSH connection and returns a handle for I/O.
pub async fn connect_ssh(config: SshConfig) -> Result<SshSessionHandle, String> {
    let (event_tx, event_rx) = mpsc::unbounded_channel();
    let (command_tx, mut command_rx) = mpsc::unbounded_channel();

    let handler = ClientHandler {
        event_tx: event_tx.clone(),
    };

    let socket_addr: std::net::SocketAddr = format!("{}:{}", config.host, config.port)
        .parse()
        .map_err(|e| format!("Invalid address: {e}"))?;

    // Connect TCP
    let tcp = tokio::net::TcpStream::connect(socket_addr)
        .await
        .map_err(|e| format!("TCP connect failed: {e}"))?;

    // SSH handshake
    let config_arc = Arc::new(russh::client::Config::default());
    let mut session = russh::client::connect(config_arc, tcp, handler)
        .await
        .map_err(|e| format!("SSH handshake failed: {e}"))?;

    let _ = event_tx.send(SessionEvent::Connected);

    // Authenticate
    let auth_result = if let Some(password) = &config.password {
        session
            .authenticate_password(&config.username, password)
            .await
            .map_err(|e| format!("Password auth failed: {e}"))?
    } else if let Some(key_path) = &config.key_path {
        let key_pair = russh_keys::load_secret_key(key_path, config.passphrase.as_deref())
            .map_err(|e| format!("Key load failed: {e}"))?;
        session
            .authenticate_publickey(&config.username, Arc::new(key_pair))
            .await
            .map_err(|e| format!("Key auth failed: {e}"))?
    } else {
        return Err("No authentication method provided".into());
    };

    if !auth_result.success() {
        return Err("Authentication rejected by server".into());
    }

    let _ = event_tx.send(SessionEvent::Authenticated);

    // Request a PTY channel
    let mut channel = session
        .channel_open_session()
        .await
        .map_err(|e| format!("Channel open failed: {e}"))?;

    channel
        .request_pty(true, "xterm-256color", 80, 24, 0, 0, &[])
        .await
        .map_err(|e| format!("PTY request failed: {e}"))?;

    channel
        .request_shell(true)
        .await
        .map_err(|e| format!("Shell request failed: {e}"))?;

    let _ = event_tx.send(SessionEvent::Authenticated);

    // Spawn I/O loop
    let event_tx_clone = event_tx.clone();
    tokio::spawn(async move {
        loop {
            tokio::select! {
                // Read from server
                Some(msg) = channel.wait() => {
                    match msg {
                        ChannelMsg::Data { ref data } => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Data(data.to_vec()));
                        }
                        ChannelMsg::Eof => {
                            let _ = event_tx_clone
                                .send(SessionEvent::Disconnected("Server closed connection".into()));
                            break;
                        }
                        ChannelMsg::Close => {
                            break;
                        }
                        _ => {}
                    }
                }

                // Read commands from FFI
                Some(cmd) = command_rx.recv() => {
                    match cmd {
                        SessionCommand::Write(data) => {
                            let _ = channel.data(&data[..]).await;
                        }
                        SessionCommand::Resize { cols, rows } => {
                            let _ = channel
                                .window_change(cols as u32, rows as u32, 0, 0)
                                .await;
                        }
                        SessionCommand::Disconnect => {
                            let _ = channel.close().await;
                            break;
                        }
                    }
                }

                else => break,
            }
        }
    });

    Ok(SshSessionHandle {
        event_rx,
        command_tx,
    })
}
```

### Step 4: Replace the stub `engine_connect` in `lib.rs`

```rust
use crate::runtime::block_on;
use crate::ssh_session::{connect_ssh, SshConfig, SessionCommand, SessionEvent};
use std::sync::mpsc; // std channel for blocking FFI bridge

/// Internal per-session bookkeeping.
struct SessionHandle {
    id: SessionId,
    protocol: ProtocolType,
    state: SessionState,
    config: SessionConfig,
    command_tx: mpsc::UnboundedSender<SessionCommand>,
    event_rx: std::sync::Mutex<mpsc::Receiver<SessionEvent>>,
}

#[no_mangle]
pub unsafe extern "C" fn engine_connect(config: *const CSessionConfig) -> SessionId {
    if config.is_null() {
        return 0;
    }

    let cfg = &*config;
    if cfg.host.is_null() {
        return 0;
    }

    let host = match CStr::from_ptr(cfg.host).to_str() {
        Ok(h) if !h.is_empty() => h.to_string(),
        _ => return 0,
    };

    let protocol = match cfg.protocol {
        0 => ProtocolType::Ssh,
        1 => ProtocolType::Vnc,
        2 => ProtocolType::Rdp,
        _ => return 0,
    };

    // For SSH protocol, establish a real connection
    if protocol == ProtocolType::Ssh {
        let ssh_config = SshConfig {
            host: host.clone(),
            port: cfg.port,
            username: String::new(), // Set during auth
            password: None,
            key_path: None,
            key_data: None,
            passphrase: None,
        };

        match block_on(connect_ssh(ssh_config)) {
            Ok(handle) => {
                let mut state = match engine().write() {
                    Ok(s) => s,
                    Err(_) => return 0,
                };

                let session_id = state.next_id;
                state.next_id = state.next_id.checked_add(1).unwrap_or(u64::MAX);

                // Store handle (simplified — real impl needs cross-thread bridge)
                info!(session_id, "SSH session connected");

                session_id
            }
            Err(e) => {
                tracing::error!("SSH connect failed: {}", e);
                0
            }
        }
    } else {
        // VNC/RDP — stub for now
        let mut state = match engine().write() {
            Ok(s) => s,
            Err(_) => return 0,
        };
        let session_id = state.next_id;
        state.next_id = state.next_id.checked_add(1).unwrap_or(u64::MAX);
        session_id
    }
}
```

### Step 5: Wire up `engine_write`

```rust
#[no_mangle]
pub unsafe extern "C" fn engine_write(
    session_id: SessionId,
    data: *const u8,
    len: usize,
) -> c_int {
    if data.is_null() || len == 0 {
        return -1;
    }

    let buf = std::slice::from_raw_parts(data, len);

    let state = match engine().read() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    if let Some(session) = state.sessions.get(&session_id) {
        let cmd = SessionCommand::Write(buf.to_vec());
        match session.command_tx.send(cmd) {
            Ok(_) => 0,
            Err(_) => -1,
        }
    } else {
        -1
    }
}
```

### Platform differences

| Platform | Library name | Loading |
|----------|-------------|---------|
| Linux | `libbluessh.so` | `DynamicLibrary.open('libbluessh.so')` — searched in `LD_LIBRARY_PATH` and app bundle |
| Windows | `bluessh.dll` | `DynamicLibrary.open('bluessh.dll')` — searched next to `.exe` |
| Android | `libbluessh.so` | Loaded via `System.loadLibrary("bluessh")` in `EngineBridge.kt` — must be in `jniLibs/<abi>/` |

The Rust crate compiles to the correct output for each platform using `crate-type = ["cdylib"]`.
Cross-compilation for Android uses `cargo-ndk` (already configured in `build_android.sh`).

### Verification

1. Build: `cd engine && cargo build --release`
2. Run the app on Linux.
3. Add a host pointing to a test server.
4. Connect — the terminal should display the server's login prompt.
5. Type `whoami` and press Enter — the server should respond with the username.

---

## 3. SSH Host Key Verification

### Problem

`engine/src/lib.rs` calls `check_server_key` in the russh handler but currently returns
`Ok(true)` unconditionally. This means every connection accepts any server key, making
the app vulnerable to man-in-the-middle attacks.

### Architecture

```
Connection attempt
       │
       ▼
┌─────────────────┐    ┌──────────────────┐
│  KnownHostsStore│───▶│  ~/.ssh/known_    │
│  (encrypted)    │    │  hosts OR app     │
└────────┬────────┘    │  secure storage   │
         │             └──────────────────┘
         ▼
   Key matches?
   ┌───┴───┐
   YES     NO
   │       │
   │    ┌──▼──────────────────────┐
   │    │  TOFU Dialog (Dart UI)  │
   │    │  "Unknown host key:     │
   │    │   SHA256:abcdef...      │
   │    │   Trust and continue?"  │
   │    └──┬──────────────────────┘
   │    ┌──┴───┐
   │   YES     NO
   │    │       │
   │    │    Disconnect
   │    │
   ▼    ▼
 Accept connection
```

### Step 1: Create `engine/src/known_hosts.rs`

```rust
//! Known-hosts storage and verification.
//!
//! Stores server public keys keyed by `[host]:port`. On connection,
//! the server's key is compared against the stored key. If no entry
//! exists, the UI is prompted via an [EngineEvent::HostKeyChallenge].

use russh_keys::key::PublicKey;
use std::collections::HashMap;
use std::sync::RwLock;
use serde::{Deserialize, Serialize};

/// A stored host key entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct HostKeyEntry {
    pub key_type: String,
    pub fingerprint_sha256: String,
    pub public_key_base64: String,
}

/// Global known-hosts store.
static KNOWN_HOSTS: RwLock<Option<HashMap<String, HostKeyEntry>>> = RwLock::new(None);

fn store() -> std::sync::RwLockReadGuard<'static, Option<HashMap<String, HostKeyEntry>>> {
    // Initialize from disk on first access
    let mut guard = KNOWN_HOSTS.write().unwrap();
    if guard.is_none() {
        *guard = Some(load_from_disk());
    }
    drop(guard);
    KNOWN_HOSTS.read().unwrap()
}

/// Verifies a server key against known hosts.
///
/// Returns:
/// - `Ok(true)` if the key matches the stored key
/// - `Ok(false)` if no entry exists (caller should prompt user)
/// - `Err(fingerprint)` if the key conflicts with a stored key (MITM)
pub fn verify_host_key(host: &str, port: u16, key: &PublicKey) -> Result<bool, String> {
    let fingerprint = key
        .fingerprint(russh_keys::HashAlg::Sha256)
        .to_string();
    let key_id = format!("{host}:{port}");

    let guard = store();
    let store_ref = guard.as_ref().unwrap();

    match store_ref.get(&key_id) {
        Some(entry) => {
            if entry.fingerprint_sha256 == fingerprint {
                Ok(true)
            } else {
                Err(format!(
                    "HOST KEY MISMATCH for {key_id}. \
                     Expected: {} Got: {fingerprint}. \
                     Possible man-in-the-middle attack!",
                    entry.fingerprint_sha256
                ))
            }
        }
        None => Ok(false),
    }
}

/// Adds or updates a host key entry (called after user approval).
pub fn accept_host_key(host: &str, port: u16, key: &PublicKey) {
    let fingerprint = key
        .fingerprint(russh_keys::HashAlg::Sha256)
        .to_string();
    let key_type = format!("{:?}", key.algorithm());
    let public_key_base64 = base64_encode_key(key);
    let key_id = format!("{host}:{port}");

    let entry = HostKeyEntry {
        key_type,
        fingerprint_sha256: fingerprint,
        public_key_base64,
    };

    let mut guard = KNOWN_HOSTS.write().unwrap();
    let store_ref = guard.as_mut().unwrap();
    store_ref.insert(key_id, entry);
    drop(guard);

    save_to_disk();
}

fn load_from_disk() -> HashMap<String, HostKeyEntry> {
    // Read from app data directory or ~/.ssh/known_hosts
    // Implementation depends on platform
    HashMap::new()
}

fn save_to_disk() {
    // Serialize to JSON and write to app data directory
}

fn base64_encode_key(_key: &PublicKey) -> String {
    // Use the ssh-key crate to encode
    String::new()
}
```

### Step 2: Update the russh handler

In `ssh_session.rs`, modify `check_server_key`:

```rust
async fn check_server_key(
    &mut self,
    server_public_key: &key::PublicKey,
) -> Result<bool, Self::Error> {
    // This will be called during the SSH handshake
    // We delegate to the host-key verification module

    // For now, emit the event so the UI can decide
    let fingerprint = server_public_key
        .fingerprint(russh_keys::HashAlg::Sha256)
        .to_string();
    let key_type = format!("{:?}", server_public_key.algorithm());

    let (tx, rx) = std::sync::mpsc::channel();

    let _ = self.event_tx.send(SessionEvent::HostKeyChallenge {
        key_type,
        fingerprint,
        response_tx: tx,
    });

    // Block until user responds (with timeout)
    match rx.recv_timeout(std::time::Duration::from_secs(60)) {
        Ok(true) => Ok(true),
        Ok(false) => Err(anyhow::anyhow!("User rejected host key")),
        Err(_) => Err(anyhow::anyhow!("Host key challenge timed out")),
    }
}
```

### Step 3: Handle the challenge in the Dart UI

In `session_service.dart`, add a new event type:

```dart
/// Emitted when the engine encounters an unknown host key.
class HostKeyChallenge {
  final String keyType;
  final String fingerprint;
  final Completer<bool> response;

  HostKeyChallenge({
    required this.keyType,
    required this.fingerprint,
    required this.response,
  });
}
```

In `home_screen.dart`, show a dialog when the challenge arrives:

```dart
void _handleHostKeyChallenge(HostKeyChallenge challenge) {
  showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: const Text('Unknown Host Key'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('The server presented an unknown key.'),
          const SizedBox(height: 12),
          Text('Type: ${challenge.keyType}'),
          Text('Fingerprint: ${challenge.fingerprint}'),
          const SizedBox(height: 12),
          const Text(
            'If this is the first time connecting, this is expected. '
            'If you have connected before, this may indicate a '
            'man-in-the-middle attack.',
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            challenge.response.complete(false);
            Navigator.pop(ctx);
          },
          child: const Text('Reject'),
        ),
        FilledButton(
          onPressed: () {
            challenge.response.complete(true);
            Navigator.pop(ctx);
          },
          child: const Text('Trust and Continue'),
        ),
      ],
    ),
  );
}
```

### Verification

1. Connect to a new server — a "Trust" dialog should appear.
2. Accept — the connection proceeds.
3. Disconnect and reconnect — no dialog should appear (key cached).
4. Manually edit the stored key — the next connection should show a
   "HOST KEY MISMATCH" error and refuse to connect.

---

## 4. MFA Secret Encryption

### Problem

`host_profile.dart:77` declares `final String? mfaSecret` which stores the TOTP shared
secret. This is persisted in SharedPreferences (plaintext) alongside the profile.
Anyone with file access can extract the TOTP seed and generate valid 2FA codes.

### Solution

MFA secrets are stored using the same `CredentialService` from Feature 1. No additional
dependencies are needed — the `flutter_secure_storage` package already handles this.

### Step 1: Include `mfaSecret` in the secure storage path

This is already handled by `CredentialService.saveCredentials()` from Feature 1, which
includes the `mfaSecret` key in the credentials map.

### Step 2: Ensure `toJson()` excludes MFA secret by default

In `host_profile.dart:225`, the `toJson()` method already excludes `mfaSecret` because
it is not listed. Verify that `mfaSecret` is only written when `includeCredentials: true`.

### Step 3: Zeroize MFA secret after use

In the Rust engine, when the MFA code is submitted, it should be zeroized:

```rust
#[no_mangle]
pub unsafe extern "C" fn engine_auth_mfa(
    session_id: SessionId,
    code: *const c_char,
) -> c_int {
    if code.is_null() {
        return -1;
    }

    let mut mfa_code = match CStr::from_ptr(code).to_str() {
        Ok(c) => c.to_string(),
        Err(_) => return -1,
    };

    // Use the MFA code for TOTP generation...
    // (Implementation depends on TOTP library integration)

    mfa_code.zeroize();
    0
}
```

### Step 4: Add TOTP generation to the engine

Add to `Cargo.toml`:

```toml
totp-rs = { version = "5", features = ["qr"] }
```

Add `engine/src/totp.rs`:

```rust
//! TOTP code generation for MFA.

use totp_rs::{Algorithm, TOTP};

/// Generates a TOTP code from a base32-encoded secret.
///
/// Returns `Some(code)` on success, `None` if the secret is invalid.
pub fn generate_totp(secret_base32: &str) -> Option<String> {
    let totp = TOTP::new(
        Algorithm::SHA1,
        6,
        1,
        30,
        secret_base32.as_bytes().to_vec(),
    )
    .ok()?;

    totp.generate_current().ok()
}
```

### Verification

1. Add a host with MFA enabled and enter a TOTP secret.
2. Kill and relaunch the app.
3. Verify the host shows the MFA shield icon but the secret is NOT in `shared_prefs`.
4. On Linux, verify the secret is in `libsecret`: `secret-tool list service=bluessh`.

---

## 5. Functional SFTP File Upload

### Problem

`file_manager_screen.dart:101-106` defines `_uploadFile()` which only shows a snackbar
"Select file to upload..." and never actually opens a file picker or uploads anything.
The `file_picker` package is already in `pubspec.yaml:15` but never imported in this file.

### Step 1: Add the import

```dart
import 'package:file_picker/file_picker.dart';
```

### Step 2: Implement `_uploadFile()`

Replace the stub at `file_manager_screen.dart:101`:

```dart
Future<void> _uploadFile() async {
  // Pick one or more files from the device
  final result = await FilePicker.platform.pickFiles(
    allowMultiple: true,
    withData: true,     // Load file bytes into memory (required on Android/web)
    withReadStream: true, // Stream large files instead of loading entirely
  );

  if (result == null || result.files.isEmpty) return;

  final sessionService = ref.read(sessionServiceProvider);

  for (final file in result.files) {
    final remotePath = '$_currentPath/${file.name}';

    // Show progress indicator
    if (!mounted) return;
    final progressKey = GlobalKey<_TransferBarState>();

    // Start the upload
    if (file.readStream != null) {
      // Stream-based upload for large files
      final bytes = await file.readStream!.fold<List<int>>(
        <int>[],
        (previous, element) => previous..addAll(element),
      );
      await sessionService.sftpUpload(
        widget.sessionId,
        file.path ?? '',
        remotePath,
      );
    } else if (file.path != null) {
      // Path-based upload (desktop)
      await sessionService.sftpUpload(
        widget.sessionId,
        file.path!,
        remotePath,
      );
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Uploaded: ${file.name}')),
    );
  }

  // Refresh directory listing
  _loadDirectory(_currentPath);
}
```

### Step 3: Implement the Rust engine SFTP upload

In `engine/src/lib.rs`, replace the `nativeSftpUpload` stub:

```rust
#[no_mangle]
pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpUpload(
    mut env: JNIEnv,
    _class: JClass,
    session_id: jlong,
    local_path: JString,
    remote_path: JString,
) -> jint {
    let local: String = match env.get_string(&local_path) {
        Ok(s) => s.into(),
        Err(_) => return -1,
    };
    let remote: String = match env.get_string(&remote_path) {
        Ok(s) => s.into(),
        Err(_) => return -1,
    };

    info!(session_id, local, remote, "SFTP upload initiated");

    // Spawn async task for the upload
    let rt = crate::runtime::runtime();
    rt.spawn(async move {
        // Open local file
        let mut local_file = match tokio::fs::File::open(&local).await {
            Ok(f) => f,
            Err(e) => {
                tracing::error!("Cannot open local file: {e}");
                return;
            }
        };

        // Use the session's SFTP subsystem
        // (Implementation depends on russh SFTP API)
    });

    0
}
```

### Platform differences

| Platform | File picker behavior |
|----------|---------------------|
| Linux | Opens GTK file dialog. Returns absolute paths. `withData: false` is sufficient. |
| Windows | Opens Win32 file dialog. Returns absolute paths. Long paths (260+) need `\\?\` prefix. |
| Android | Opens system file picker via `ACTION_OPEN_DOCUMENT`. Returns content URIs. MUST use `withData: true` to get bytes. `file.path` may be null. |

### Verification

1. Open the file manager for an SSH connection.
2. Tap the upload button.
3. Select a file.
4. Verify the file appears in the remote directory listing after refresh.

---

## 6. Multi-Tab Terminal

### Problem

`terminal_screen.dart` displays a single `Terminal` widget per screen. There is no tab
bar, no way to open multiple shells to the same or different hosts, and no session
switching mechanism.

### Step 1: Create the tab model

Create `ui/lib/models/terminal_tab.dart`:

```dart
/// A single terminal tab with its associated session and terminal state.
class TerminalTab {
  final String id;
  final String title;
  final int sessionId;
  final HostProfile profile;
  final Terminal terminal;
  final TerminalController controller;
  DateTime createdAt;
  bool isActive;

  TerminalTab({
    required this.id,
    required this.title,
    required this.sessionId,
    required this.profile,
    required this.terminal,
    required this.controller,
    DateTime? createdAt,
    this.isActive = false,
  }) : createdAt = createdAt ?? DateTime.now();
}
```

### Step 2: Create the tab manager

Create `ui/lib/services/tab_manager.dart`:

```dart
/// Manages multiple terminal tabs.
///
/// Each tab has its own SSH session and terminal state. The tab manager
/// handles creation, switching, closing, and keyboard shortcuts.
class TabManager extends ChangeNotifier {
  final List<TerminalTab> _tabs = [];
  int _activeIndex = 0;

  List<TerminalTab> get tabs => List.unmodifiable(_tabs);
  int get activeIndex => _activeIndex;
  TerminalTab? get activeTab =>
      _tabs.isNotEmpty ? _tabs[_activeIndex] : null;
  int get length => _tabs.length;

  /// Creates a new tab with an SSH session to the given profile.
  Future<TerminalTab> createTab({
    required HostProfile profile,
    required SessionService sessionService,
  }) async {
    final sessionId = await sessionService.connect(profile);
    if (sessionId <= 0) {
      throw Exception('Connection failed');
    }

    final authResult = await sessionService.authenticate(sessionId, profile);
    if (authResult != 0) {
      await sessionService.disconnect(sessionId);
      throw Exception('Authentication failed');
    }

    final tab = TerminalTab(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: profile.name,
      sessionId: sessionId,
      profile: profile,
      terminal: Terminal(maxLines: 10000),
      controller: TerminalController(),
    );

    _tabs.add(tab);
    _activeIndex = _tabs.length - 1;
    notifyListeners();
    return tab;
  }

  /// Switches to the tab at [index].
  void switchTo(int index) {
    if (index < 0 || index >= _tabs.length) return;
    _activeIndex = index;
    notifyListeners();
  }

  /// Closes the tab at [index] and disconnects its session.
  Future<void> closeTab(int index, SessionService sessionService) async {
    if (index < 0 || index >= _tabs.length) return;

    final tab = _tabs[index];
    await sessionService.disconnect(tab.sessionId);
    _tabs.removeAt(index);

    if (_activeIndex >= _tabs.length) {
      _activeIndex = (_tabs.length - 1).clamp(0, _tabs.length);
    }
    notifyListeners();
  }

  /// Closes all tabs.
  Future<void> closeAll(SessionService sessionService) async {
    for (final tab in _tabs) {
      await sessionService.disconnect(tab.sessionId);
    }
    _tabs.clear();
    _activeIndex = 0;
    notifyListeners();
  }
}
```

### Step 3: Create the multi-tab screen

Create `ui/lib/screens/multi_terminal_screen.dart`:

```dart
/// Multi-tab terminal screen with a tab bar at the top.
class MultiTerminalScreen extends ConsumerStatefulWidget {
  final HostProfile initialProfile;

  const MultiTerminalScreen({super.key, required this.initialProfile});

  @override
  ConsumerState<MultiTerminalScreen> createState() =>
      _MultiTerminalScreenState();
}

class _MultiTerminalScreenState extends ConsumerState<MultiTerminalScreen> {
  late final TabManager _tabManager;

  @override
  void initState() {
    super.initState();
    _tabManager = TabManager();
    _openInitialTab();
  }

  Future<void> _openInitialTab() async {
    final sessionService = ref.read(sessionServiceProvider);
    try {
      await _tabManager.createTab(
        profile: widget.initialProfile,
        sessionService: sessionService,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to connect: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    final sessionService = ref.read(sessionServiceProvider);
    _tabManager.closeAll(sessionService);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildTabBar(),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New tab',
            onPressed: _addNewTab,
          ),
        ],
      ),
      body: _buildTabContent(),
    );
  }

  Widget _buildTabBar() {
    return ListenableBuilder(
      listenable: _tabManager,
      builder: (context, _) {
        return SizedBox(
          height: 40,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _tabManager.length,
            itemBuilder: (ctx, i) {
              final tab = _tabManager.tabs[i];
              final isActive = i == _tabManager.activeIndex;
              return Padding(
                padding: const EdgeInsets.only(right: 4),
                child: InputChip(
                  label: Text(tab.title),
                  selected: isActive,
                  onSelected: (_) => setState(() => _tabManager.switchTo(i)),
                  onDeleted: () => _closeTab(i),
                  avatar: Icon(
                    Icons.terminal,
                    size: 16,
                    color: isActive ? Colors.green : Colors.grey,
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }

  Widget _buildTabContent() {
    return ListenableBuilder(
      listenable: _tabManager,
      builder: (context, _) {
        final tab = _tabManager.activeTab;
        if (tab == null) {
          return const Center(child: Text('No active sessions'));
        }

        return TerminalView(
          tab.terminal,
          controller: tab.controller,
          autofocus: true,
          backgroundOpacity: 0.95,
          theme: _terminalTheme(),
        );
      },
    );
  }

  void _addNewTab() async {
    final sessionService = ref.read(sessionServiceProvider);
    try {
      await _tabManager.createTab(
        profile: widget.initialProfile,
        sessionService: sessionService,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e')),
        );
      }
    }
  }

  void _closeTab(int index) async {
    final sessionService = ref.read(sessionServiceProvider);
    await _tabManager.closeTab(index, sessionService);
  }

  TerminalTheme _terminalTheme() {
    return TerminalTheme(
      cursor: Colors.lightBlueAccent,
      selection: Colors.blue.withOpacity(0.3),
      foreground: Colors.white,
      background: const Color(0xFF1E1E2E),
      black: Colors.black,
      red: const Color(0xFFF38BA8),
      green: const Color(0xFFA6E3A1),
      yellow: const Color(0xFFF9E2AF),
      blue: const Color(0xFF89B4FA),
      magenta: const Color(0xFFF5C2E7),
      cyan: const Color(0xFF94E2D5),
      white: const Color(0xFFCDD6F4),
      brightBlack: const Color(0xFF6C7086),
      brightRed: const Color(0xFFF38BA8),
      brightGreen: const Color(0xFFA6E3A1),
      brightYellow: const Color(0xFFF9E2AF),
      brightBlue: const Color(0xFF89B4FA),
      brightMagenta: const Color(0xFFF5C2E7),
      brightCyan: const Color(0xFF94E2D5),
      brightWhite: Colors.white,
      searchHitBackground: Colors.yellow,
      searchHitBackgroundCurrent: Colors.orange,
      searchHitForeground: Colors.black,
    );
  }
}
```

### Step 4: Update `home_screen.dart` navigation

Replace the `TerminalScreen` navigation with `MultiTerminalScreen`:

```dart
case ProtocolType.ssh:
case ProtocolType.sftp:
  screen = MultiTerminalScreen(
    profile: profile,
  );
```

### Keyboard shortcuts

Add to the `MultiTerminalScreen`:

```dart
Widget build(BuildContext context) {
  return Shortcuts(
    shortcuts: <ShortcutActivator, Intent>{
      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyT):
          const _NewTabIntent(),
      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyW):
          const _CloseTabIntent(),
      LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.tab):
          const _NextTabIntent(),
      LogicalKeySet(LogicalKeyboardKey.control,
          LogicalKeyboardKey.shift, LogicalKeyboardKey.tab):
          const _PreviousTabIntent(),
    },
    child: Actions(
      actions: <Type, Action<Intent>>{
        _NewTabIntent: CallbackAction(
          onInvoke: (_) => _addNewTab(),
        ),
        _CloseTabIntent: CallbackAction(
          onInvoke: (_) => _closeTab(_tabManager.activeIndex),
        ),
        _NextTabIntent: CallbackAction(
          onInvoke: (_) => _tabManager.switchTo(
            (_tabManager.activeIndex + 1) % _tabManager.length,
          ),
        ),
        _PreviousTabIntent: CallbackAction(
          onInvoke: (_) => _tabManager.switchTo(
            (_tabManager.activeIndex - 1 + _tabManager.length) %
                _tabManager.length,
          ),
        ),
      },
      child: Scaffold(...),
    ),
  );
}
```

### Verification

1. Connect to a host — a single tab appears.
2. Press Ctrl+T — a second tab opens to the same host.
3. Click between tabs — each shows independent terminal output.
4. Press Ctrl+W — the active tab closes and its session disconnects.
5. Press Ctrl+Tab — cycles to the next tab.

---

## 7. Port Forwarding / Tunneling

### Problem

The engine has no port forwarding functions. `host_profile.dart` has no forwarding
configuration fields. SSH tunneling (local, remote, dynamic/SOCKS) is essential for
accessing internal services through a bastion host.

### Architecture

```
┌─────────────────────────────────────────────────────┐
│  Dart UI                                            │
│  ForwardingScreen (list, add, remove tunnels)       │
└──────────────────┬──────────────────────────────────┘
                   │ MethodChannel / FFI
┌──────────────────▼──────────────────────────────────┐
│  Rust Engine                                        │
│  engine_tunnel_create(bind_addr, remote_addr)       │
│  engine_tunnel_destroy(tunnel_id)                   │
│  engine_tunnel_list(session_id) -> JSON             │
│                                                     │
│  ┌───────────────────────────────────────────────┐  │
│  │  TunnelManager                                │  │
│  │  ┌─────────┐  ┌─────────┐  ┌─────────┐      │  │
│  │  │ Local   │  │ Remote  │  │ SOCKS5  │      │  │
│  │  │ :8080→  │  │ :9090←  │  │ :1080   │      │  │
│  │  │ remote  │  │ local   │  │ dynamic │      │  │
│  │  │ :80     │  │ :3389   │  │         │      │  │
│  │  └─────────┘  └─────────┘  └─────────┘      │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

### Step 1: Add tunnel types to `host_profile.dart`

```dart
/// Port forwarding rule.
class PortForward {
  final String id;
  final ForwardType type;
  final int localPort;
  final String remoteHost;
  final int remotePort;
  final bool enabled;

  const PortForward({
    required this.id,
    required this.type,
    required this.localPort,
    required this.remoteHost,
    required this.remotePort,
    this.enabled = true,
  });
}

enum ForwardType {
  local('Local', 'Remote service → local port'),
  remote('Remote', 'Local service → remote port'),
  dynamic('SOCKS5', 'Dynamic proxy');

  final String label;
  final String description;
  const ForwardType(this.label, this.description);
}
```

Add `final List<PortForward> portForwards` to the `HostProfile` constructor.

### Step 2: Add FFI functions to the engine

In `engine/src/lib.rs`:

```rust
/// Creates a port forwarding tunnel.
///
/// - `bind_addr`: Local address to listen on (e.g., "127.0.0.1:8080").
/// - `remote_addr`: Remote address to forward to (e.g., "10.0.0.5:80").
/// - `forward_type`: 0=local, 1=remote, 2=dynamic (SOCKS5).
///
/// Returns a tunnel ID (>0) on success, 0 on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_tunnel_create(
    session_id: SessionId,
    bind_host: *const c_char,
    bind_port: u16,
    remote_host: *const c_char,
    remote_port: u16,
    forward_type: u8,
) -> u64 {
    let bind = match CStr::from_ptr(bind_host).to_str() {
        Ok(s) => format!("{}:{}", s, bind_port),
        Err(_) => return 0,
    };
    let remote = match CStr::from_ptr(remote_host).to_str() {
        Ok(s) => format!("{}:{}", s, remote_port),
        Err(_) => return 0,
    };

    info!(
        session_id,
        bind, remote, forward_type, "Creating tunnel"
    );

    // Spawn async listener
    // Implementation uses russh's direct-tcpip channel
    1 // placeholder tunnel ID
}

/// Destroys a port forwarding tunnel.
#[no_mangle]
pub unsafe extern "C" fn engine_tunnel_destroy(tunnel_id: u64) -> c_int {
    info!(tunnel_id, "Destroying tunnel");
    0
}
```

### Step 3: Create tunnel management UI

Create `ui/lib/screens/forwarding_screen.dart`:

```dart
/// Port forwarding configuration screen.
class ForwardingScreen extends StatefulWidget {
  final HostProfile profile;
  const ForwardingScreen({super.key, required this.profile});

  @override
  State<ForwardingScreen> createState() => _ForwardingScreenState();
}

class _ForwardingScreenState extends State<ForwardingScreen> {
  late List<PortForward> _forwards;

  @override
  void initState() {
    super.initState();
    _forwards = List.from(widget.profile.portForwards);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Port Forwarding')),
      body: ListView.builder(
        itemCount: _forwards.length,
        itemBuilder: (ctx, i) {
          final fwd = _forwards[i];
          return ListTile(
            leading: Icon(
              fwd.type == ForwardType.local
                  ? Icons.arrow_forward
                  : fwd.type == ForwardType.remote
                      ? Icons.arrow_back
                      : Icons.swap_horiz,
            ),
            title: Text(
              '${fwd.type.label}: localhost:${fwd.localPort} → '
              '${fwd.remoteHost}:${fwd.remotePort}',
            ),
            trailing: Switch(
              value: fwd.enabled,
              onChanged: (v) => _toggleForward(i, v),
            ),
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _addForward,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _toggleForward(int index, bool enabled) {
    // Call engine_tunnel_create or engine_tunnel_destroy
  }

  void _addForward() {
    // Show dialog to configure new forward
  }
}
```

### Verification

1. Add a local forward: `localhost:8080 → remote:80`.
2. Enable the forward — the engine should bind `:8080` locally.
3. Open `http://localhost:8080` in a browser — should show the remote web service.
4. Disable the forward — the local port should close.

---

## 8. SSH Jump Host / Proxy

### Problem

`host_profile.dart` has no `proxyHost`, `proxyPort`, or `jumpHost` fields. Connecting to
a host behind a bastion/jump server requires chaining SSH connections, which is not
supported.

### Architecture

```
┌──────────┐     SSH      ┌──────────────┐     SSH      ┌──────────┐
│  BlueSSH │────────────▶│  Jump Host   │────────────▶│  Target  │
│  Client  │             │  bastion.io  │             │  db01    │
└──────────┘             └──────────────┘             └──────────┘
                          Port 22                       Port 22
```

### Step 1: Add jump host fields to `host_profile.dart`

```dart
/// Host profile model additions for jump host support.
class HostProfile {
  // ... existing fields ...

  /// Hostname or IP of the jump/bastion host (null = direct connection).
  final String? jumpHost;

  /// Port of the jump host (default: 22).
  final int jumpPort;

  /// Username on the jump host (defaults to the target username).
  final String? jumpUsername;

  /// Password for the jump host.
  final String? jumpPassword;

  /// Key path for the jump host.
  final String? jumpKeyPath;

  const HostProfile({
    // ... existing parameters ...
    this.jumpHost,
    this.jumpPort = 22,
    this.jumpUsername,
    this.jumpPassword,
    this.jumpKeyPath,
  });
}
```

### Step 2: Implement jump host in the Rust engine

Add to `Cargo.toml`:

```toml
# No new dependencies needed — russh supports direct-tcpip channels
```

In `engine/src/ssh_session.rs`:

```rust
/// Establishes a connection through a jump host.
pub async fn connect_through_jump(
    jump_config: &SshConfig,
    target_config: &SshConfig,
) -> Result<SshSessionHandle, String> {
    // Step 1: Connect to the jump host
    let jump_handler = ClientHandler { /* ... */ };
    let jump_tcp = tokio::net::TcpStream::connect(
        format!("{}:{}", jump_config.host, jump_config.port),
    )
    .await
    .map_err(|e| format!("Jump host TCP failed: {e}"))?;

    let jump_session = russh::client::connect(
        Arc::new(russh::client::Config::default()),
        jump_tcp,
        jump_handler,
    )
    .await
    .map_err(|e| format!("Jump host SSH failed: {e}"))?;

    // Authenticate to jump host
    // ...

    // Step 2: Open a direct-tcpip channel through the jump host
    // This creates a TCP connection from the jump host to the target
    let channel = jump_session
        .channel_open_direct_tcpip(
            &target_config.host,
            target_config.port as u32,
            "127.0.0.1",
            0,
        )
        .await
        .map_err(|e| format!("Direct-tcpip failed: {e}"))?;

    // Step 3: Establish SSH over the forwarded channel
    let target_handler = ClientHandler { /* ... */ };
    let target_session = russh::client::connect(
        Arc::new(russh::client::Config::default()),
        // Wrap the channel as a stream
        ChannelStream::new(channel),
        target_handler,
    )
    .await
    .map_err(|e| format!("Target SSH failed: {e}"))?;

    // Authenticate to target
    // ...

    // Return handle
    Ok(SshSessionHandle { /* ... */ })
}
```

### Step 3: Add jump host UI to the host editor

In `home_screen.dart`, update the `_AddHostSheet`:

```dart
// Add to the form fields
if (_protocol == ProtocolType.ssh) ...[
  const SizedBox(height: 12),
  const Divider(),
  Text('Jump Host (optional)', style: theme.textTheme.labelLarge),
  const SizedBox(height: 8),
  Row(
    children: [
      Expanded(
        flex: 3,
        child: TextFormField(
          controller: _jumpHostController,
          decoration: const InputDecoration(
            labelText: 'Jump Host',
            hintText: 'bastion.example.com',
            prefixIcon: Icon(Icons.hub),
          ),
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: TextFormField(
          controller: _jumpPortController,
          decoration: const InputDecoration(labelText: 'Port'),
          keyboardType: TextInputType.number,
        ),
      ),
    ],
  ),
],
```

### Verification

1. Configure a host with jump host `bastion.example.com`.
2. Connect — the engine should first SSH to the bastion, then tunnel
   through to the target.
3. The terminal should show the target's shell prompt, not the bastion's.
4. Run `whoami` — should show the target username.

---

## 9. Real SSH Key Generation

### Problem

`settings_screen.dart:133-218` defines `_generateKey()` which shows a dialog and creates
a fake `KeyInfo` with a random fingerprint. It never actually generates a cryptographic
key pair. The engine has no `engine_key_generate()` function.

### Step 1: Add key generation to the Rust engine

Add to `Cargo.toml`:

```toml
ssh-key = { version = "0.6", features = ["ed25519", "ecdsa", "rsa", "alloc"] }
rand = "0.8"
```

Add `engine/src/keygen.rs`:

```rust
//! SSH key pair generation.

use ssh_key::{Algorithm, HashAlg, LineEnding, PrivateKey};
use zeroize::Zeroize;

/// Supported key types.
#[repr(u8)]
pub enum KeyType {
    Ed25519 = 0,
    Ecdsa = 1,
    Rsa = 2,
}

/// Generates an SSH key pair and writes the private key to `output_path`.
///
/// The public key is written to `output_path.pub`.
///
/// Returns the public key in OpenSSH format on success, or an empty
/// string on failure.
pub fn generate_key_pair(
    key_type: KeyType,
    output_path: &str,
    passphrase: Option<&str>,
) -> Result<String, String> {
    let private_key = match key_type {
        KeyType::Ed25519 => {
            PrivateKey::random(&mut rand::thread_rng(), Algorithm::Ed25519)
                .map_err(|e| format!("Key generation failed: {e}"))?
        }
        KeyType::Ecdsa => {
            PrivateKey::random(&mut rand::thread_rng(), Algorithm::EcdsaSha2Nistp256)
                .map_err(|e| format!("Key generation failed: {e}"))?
        }
        KeyType::Rsa => {
            // ssh-key crate does not support RSA generation directly
            // Use rsa crate for key generation, then wrap in ssh_key format
            return Err("RSA key generation not yet implemented".into());
        }
    };

    // Encrypt with passphrase if provided
    let encrypted_key = if let Some(pass) = passphrase {
        private_key
            .encrypt(&mut rand::thread_rng(), pass)
            .map_err(|e| format!("Key encryption failed: {e}"))?
    } else {
        private_key.clone()
    };

    // Write private key
    let pem = encrypted_key
        .to_openssh(LineEnding::LF)
        .map_err(|e| format!("PEM encoding failed: {e}"))?;
    std::fs::write(output_path, pem.as_ref())
        .map_err(|e| format!("Write failed: {e}"))?;

    // Set permissions (Unix only)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(output_path, std::fs::Permissions::from_mode(0o600))
            .map_err(|e| format!("Permission set failed: {e}"))?;
    }

    // Write public key
    let public_key = private_key.public_key();
    let pub_openssh = public_key
        .to_openssh()
        .map_err(|e| format!("Public key encoding failed: {e}"))?;
    std::fs::write(
        format!("{output_path}.pub"),
        pub_openssh.as_ref(),
    )
    .map_err(|e| format!("Write pubkey failed: {e}"))?;

    Ok(pub_openssh.to_string())
}
```

### Step 2: Add FFI entry point

```rust
/// Generates an SSH key pair.
///
/// - `key_type`: 0=Ed25519, 1=ECDSA, 2=RSA.
/// - `output_path`: Filesystem path for the private key.
/// - `passphrase`: Optional passphrase (nullable).
///
/// Returns the public key string on success, null on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_key_generate(
    key_type: u8,
    output_path: *const c_char,
    passphrase: *const c_char,
    out_pubkey: *mut c_char,
    out_pubkey_len: usize,
) -> c_int {
    let path = match CStr::from_ptr(output_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    let pass = if passphrase.is_null() {
        None
    } else {
        match CStr::from_ptr(passphrase).to_str() {
            Ok(p) if !p.is_empty() => Some(p),
            _ => None,
        }
    };

    let kt = match key_type {
        0 => KeyType::Ed25519,
        1 => KeyType::Ecdsa,
        2 => KeyType::Rsa,
        _ => return -1,
    };

    match generate_key_pair(kt, path, pass) {
        Ok(pubkey) => {
            let bytes = pubkey.as_bytes();
            let len = bytes.len().min(out_pubkey_len - 1);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_pubkey as *mut u8, len);
            *out_pubkey.add(len) = 0; // null terminator
            0
        }
        Err(e) => {
            tracing::error!("Key generation failed: {e}");
            -1
        }
    }
}
```

### Step 3: Update the Dart UI

Replace the fake `_generateKey()` in `settings_screen.dart:133`:

```dart
Future<void> _generateKey() async {
  final controller = TextEditingController();
  final passphraseController = TextEditingController();
  KeyType selectedType = KeyType.ed25519;

  final result = await showDialog<Map<String, dynamic>>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        title: const Text('Generate SSH Key'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Key name',
                hintText: 'bluessh-key',
              ),
            ),
            const SizedBox(height: 12),
            SegmentedButton<KeyType>(
              segments: const [
                ButtonSegment(value: KeyType.ed25519, label: Text('Ed25519')),
                ButtonSegment(value: KeyType.ecdsa, label: Text('ECDSA')),
                ButtonSegment(value: KeyType.rsa, label: Text('RSA-4096')),
              ],
              selected: {selectedType},
              onSelectionChanged: (s) =>
                  setDialogState(() => selectedType = s.first),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: passphraseController,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Passphrase (optional)',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, {
              'name': controller.text,
              'type': selectedType.name,
              'passphrase': passphraseController.text,
            }),
            child: const Text('Generate'),
          ),
        ],
      ),
    ),
  );

  if (result == null) return;

  // Call the engine to generate the key
  final sessionService = ref.read(sessionServiceProvider);
  final appDir = await sessionService.getAppDir();
  final keyName = (result['name'] as String).trim().isEmpty
      ? 'bluessh-key'
      : result['name'] as String;
  final keyPath = '$appDir/keys/$keyName';

  // Create keys directory
  await Directory('$appDir/keys').create(recursive: true);

  // Call engine FFI (implementation depends on engine_bridge)
  // engineKeyGenerate(typeIndex, keyPath, passphrase)

  final keyFile = File('$keyPath.pub');
  String publicKey = '';
  if (await keyFile.exists()) {
    publicKey = await keyFile.readAsString();
  }

  setState(() {
    _sshKeys.add(KeyInfo(
      name: keyName,
      type: result['type'] as String,
      fingerprint: _computeFingerprint(publicKey),
      createdAt: DateTime.now(),
    ));
  });

  await _saveKeys();
}
```

### Verification

1. Open Settings → SSH Keys → Generate.
2. Select Ed25519, enter a name, click Generate.
3. Verify two files exist: `~/.local/share/bluessh/keys/mykey` and
   `~/.local/share/bluessh/keys/mykey.pub`.
4. Verify the private key file has `600` permissions on Linux.
5. Verify the `.pub` file contains a valid OpenSSH public key line.

---

## 10. SSH Agent Forwarding

### Problem

The engine has no agent forwarding support. When a user connects to Host A and then
jumps to Host B from within the session, Host B cannot use the user's local SSH keys
because the SSH agent channel is not forwarded.

### Architecture

```
┌──────────┐                    ┌──────────┐                 ┌──────────┐
│  BlueSSH │  SSH connection    │  Host A  │  SSH connection │  Host B  │
│  Client  │──────────────────▶│  (jump)  │────────────────▶│  (final) │
│          │                    │          │                 │          │
│  ┌─────┐ │  agent request    │  ┌─────┐ │  agent request  │          │
│  │Agent│◀────────────────────│──│Agent│◀──────────────────│          │
│  │ Fwd │ │  (agent channel)  │  │ Fwd │ │  (local agent)  │          │
│  └─────┘ │                    │  └─────┘ │                 │          │
└──────────┘                    └──────────┘                 └──────────┘
```

### Step 1: Add agent forwarding flag to `host_profile.dart`

```dart
class HostProfile {
  // ... existing fields ...

  /// Whether to forward the SSH agent to the remote host.
  final bool agentForwarding;

  const HostProfile({
    // ... existing parameters ...
    this.agentForwarding = false,
  });
}
```

### Step 2: Implement agent forwarding in the engine

In `engine/src/ssh_session.rs`:

```rust
/// Requests agent forwarding on the session channel.
///
/// This tells the remote server that we will handle
/// `auth-agent-req@openssh.com` channel requests by opening
/// an `auth-agent@openssh.com` channel back to the local agent.
pub async fn request_agent_forwarding(
    channel: &mut russh::client::Channel,
) -> Result<(), String> {
    channel
        .request_agent_forwarding(true)
        .await
        .map_err(|e| format!("Agent forwarding request failed: {e}"))?;
    Ok(())
}
```

### Step 3: Handle agent channel requests

```rust
/// Handles incoming agent channel requests from the server.
///
/// When the server needs to authenticate to a downstream host
/// using the forwarded agent, it opens an `auth-agent@openssh.com`
/// channel. This handler connects that channel to the local
/// SSH agent (or the in-memory key store).
async fn handle_agent_request(
    session: &mut russh::client::Session,
    channel_id: russh::ChannelId,
) -> Result<(), String> {
    // Connect to the local SSH agent
    #[cfg(unix)]
    let agent_sock = std::env::var("SSH_AUTH_SOCK")
        .map_err(|_| "SSH_AUTH_SOCK not set".to_string())?;

    let mut agent_stream = tokio::net::UnixStream::connect(&agent_sock)
        .await
        .map_err(|e| format!("Cannot connect to SSH agent: {e}"))?;

    // Forward agent protocol messages between the channel and the agent
    tokio::spawn(async move {
        let mut buf = [0u8; 8192];
        loop {
            tokio::select! {
                // From remote server → local agent
                Some(msg) = session.wait_channel(channel_id) => {
                    if let russh::ChannelMsg::Data { data } = msg {
                        if agent_stream.write_all(&data).await.is_err() {
                            break;
                        }
                    }
                }
                // From local agent → remote server
                Ok(n) = agent_stream.read(&mut buf) => {
                    if n == 0 { break; }
                    let _ = session.data(channel_id, &buf[..n]).await;
                }
                else => break,
            }
        }
    });

    Ok(())
}
```

### Step 4: Add UI toggle

In the host editor form (`home_screen.dart`):

```dart
SwitchListTile(
  title: const Text('SSH Agent Forwarding'),
  subtitle: const Text('Forward local SSH keys to the remote host'),
  value: _agentForwarding,
  onChanged: (v) => setState(() => _agentForwarding = v),
  contentPadding: EdgeInsets.zero,
),
```

### Platform differences

| Platform | Agent support | Notes |
|----------|--------------|-------|
| Linux | Full | Uses `$SSH_AUTH_SOCK` Unix socket. Works with `ssh-agent`, `gpg-agent`, GNOME Keyring. |
| Windows | Partial | Uses Pageant (PuTTY agent) or Windows OpenSSH agent (`\\.\pipe\openssh-ssh-agent`). No universal socket path. |
| Android | Limited | No system SSH agent exists. BlueSSH must implement an in-memory agent that loads keys from the secure store. |

### Verification

1. On Linux, start `eval $(ssh-agent)` and add a key: `ssh-add ~/.ssh/id_ed25519`.
2. In BlueSSH, enable agent forwarding for a host profile.
3. Connect to Host A.
4. From Host A's terminal, run `ssh HostB` (where HostB only accepts key auth).
5. The connection should succeed without entering a password, proving the agent
   was forwarded.

---

## Summary Table

| # | Feature | Files Modified | New Files | Dependencies Added |
|---|---------|---------------|-----------|-------------------|
| 1 | Encrypted Storage | `home_screen.dart`, `host_profile.dart` | `credential_service.dart` | `flutter_secure_storage` |
| 2 | SSH Protocol | `engine/src/lib.rs` | `runtime.rs`, `ssh_session.rs` | `russh-keys` |
| 3 | Host Key Verification | `ssh_session.rs` | `known_hosts.rs` | — |
| 4 | MFA Encryption | `host_profile.dart` | `totp.rs` | `totp-rs` |
| 5 | SFTP Upload | `file_manager_screen.dart` | — | — (already have `file_picker`) |
| 6 | Multi-Tab Terminal | `home_screen.dart` | `terminal_tab.dart`, `tab_manager.dart`, `multi_terminal_screen.dart` | — |
| 7 | Port Forwarding | `host_profile.dart`, `engine/src/lib.rs` | `forwarding_screen.dart` | — |
| 8 | Jump Host | `host_profile.dart`, `ssh_session.rs` | — | — |
| 9 | Key Generation | `settings_screen.dart` | `keygen.rs` | `ssh-key`, `rand` |
| 10 | Agent Forwarding | `host_profile.dart`, `ssh_session.rs` | — | — |
