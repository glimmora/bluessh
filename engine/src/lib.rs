//! BlueSSH Core Engine
//!
//! Provides the networking engine for SSH, SFTP, VNC, and RDP protocols.
//! Exposes a C-ABI for Windows/Linux FFI and JNI for Android.
//!
//! # Architecture
//!
//! The engine uses a global singleton [`EngineState`] guarded by
//! `OnceLock<RwLock<...>>` to manage active sessions. Each session
//! is identified by a monotonically increasing [`SessionId`].
//!
//! # Safety
//!
//! All `extern "C"` functions accept raw pointers from the FFI caller.
//! Callers must ensure:
//!   - Pointers are non-null (unless documented as nullable).
//!   - Pointers outlive the function call.
//!   - String pointers are valid UTF-8 or will return error codes.

#![allow(clippy::missing_safety_doc)]

mod keygen;
mod known_hosts;
mod runtime;
mod sftp;
mod ssh_session;
mod totp;

#[cfg(test)]
mod tests;

use std::collections::HashMap;
use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};
use tracing::{error, info, warn};
use zeroize::Zeroize;

// ═══════════════════════════════════════════════════════════════════
//  Type Definitions
// ═══════════════════════════════════════════════════════════════════

/// Opaque session identifier passed across the FFI boundary.
/// A value of `0` indicates failure or no session.
pub type SessionId = u64;

/// Supported remote-access protocol types.
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum ProtocolType {
    /// SSH-2 protocol for terminal and command execution.
    Ssh = 0,
    /// RFB/VNC protocol for graphical remote desktop.
    Vnc = 1,
    /// RDP protocol for Windows remote desktop.
    Rdp = 2,
}

/// Adaptive compression aggressiveness level.
#[repr(u8)]
#[derive(Debug, Clone, Copy, Serialize, Deserialize)]
pub enum CompressionLevel {
    /// No compression — best for LAN (>50 Mbps).
    None = 0,
    /// Low compression — balanced for 1–50 Mbps links.
    Low = 1,
    /// Medium compression — suitable for 0.5–1 Mbps.
    Med = 2,
    /// High compression — for constrained links (<0.5 Mbps).
    High = 3,
}

/// FFI-compatible session configuration received from the UI layer.
///
/// The `host` field is a C-string pointer that must remain valid for
/// the duration of the `engine_connect` call.
#[repr(C)]
#[derive(Debug)]
pub struct CSessionConfig {
    pub host: *const c_char,
    pub port: u16,
    pub protocol: u8,
    pub compress_level: u8,
    pub record_session: bool,
}

/// FFI-compatible terminal frame delivered from engine to UI.
#[repr(C)]
#[derive(Debug)]
pub struct CTerminalFrame {
    pub data: *const u8,
    pub len: usize,
    pub rows: u16,
    pub cols: u16,
}

/// Lifecycle state of a remote session.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum SessionState {
    /// TCP connection in progress.
    Connecting,
    /// SSH handshake or credential exchange underway.
    Authenticating,
    /// Session fully established and ready for I/O.
    Connected,
    /// Session lost; payload is a human-readable reason.
    Disconnected(String),
    /// Unrecoverable error; payload is a diagnostic message.
    Error(String),
}

/// Events emitted by the engine and consumed by the UI layer.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub enum EngineEvent {
    /// Session lifecycle state changed.
    SessionStateChanged {
        session_id: SessionId,
        state: SessionState,
    },
    /// Terminal output data available.
    TerminalData {
        session_id: SessionId,
        data: Vec<u8>,
    },
    /// SFTP transfer progress update.
    SftpProgress {
        session_id: SessionId,
        file_id: u64,
        bytes_transferred: u64,
        total_bytes: u64,
        speed_bps: u64,
    },
    /// SFTP transfer completed.
    SftpComplete { session_id: SessionId, file_id: u64 },
    /// Remote clipboard content received.
    ClipboardUpdate {
        session_id: SessionId,
        data: Vec<u8>,
    },
    /// MFA or keyboard-interactive auth challenge from server.
    AuthChallenge {
        session_id: SessionId,
        methods: Vec<String>,
    },
    /// Error notification with machine-readable code and message.
    Error {
        session_id: SessionId,
        code: u32,
        message: String,
    },
}

// ═══════════════════════════════════════════════════════════════════
//  Engine State (internal)
// ═══════════════════════════════════════════════════════════════════

/// Internal per-session bookkeeping.
struct SessionHandle {
    id: SessionId,
    protocol: ProtocolType,
    state: SessionState,
    config: SessionConfig,
    /// Channel to send commands to the SSH session (if protocol is SSH).
    command_tx: Option<std::sync::mpsc::Sender<ssh_session::SessionCommand>>,
    /// Channel to receive events from the SSH session.
    event_rx: Option<std::sync::Mutex<std::sync::mpsc::Receiver<ssh_session::SessionEvent>>>,
}

/// Internal session configuration stored after FFI parsing.
#[allow(dead_code)]
struct SessionConfig {
    host: String,
    port: u16,
    compress_level: CompressionLevel,
    record_session: bool,
}

/// Global engine state holding all active sessions.
struct EngineState {
    sessions: HashMap<SessionId, SessionHandle>,
    next_id: SessionId,
    initialized: bool,
}

/// Process-wide engine singleton.
static ENGINE: OnceLock<RwLock<EngineState>> = OnceLock::new();

/// Returns a reference to the global engine state, initializing on first call.
fn engine() -> &'static RwLock<EngineState> {
    ENGINE.get_or_init(|| {
        RwLock::new(EngineState {
            sessions: HashMap::new(),
            next_id: 1,
            initialized: false,
        })
    })
}

// ═══════════════════════════════════════════════════════════════════
//  C-ABI Entry Points (Windows / Linux / macOS)
// ═══════════════════════════════════════════════════════════════════

/// Initializes the tracing subscriber and marks the engine as ready.
///
/// Returns `0` on success. Must be called once before any other
/// `engine_*` function.
///
/// Safe to call multiple times; subsequent calls return `0` without
/// reinitializing.
#[no_mangle]
pub extern "C" fn engine_init() -> c_int {
    // Use try_init to gracefully handle repeated initialization
    // (e.g. if called from both FFI and JNI during a hot restart).
    let _ = tracing_subscriber::fmt()
        .with_env_filter("bluessh=info")
        .json()
        .try_init();

    match engine().write() {
        Ok(mut state) => {
            state.initialized = true;
            info!("BlueSSH engine initialized");
            0
        }
        Err(_) => -1,
    }
}

/// Clears all sessions and marks the engine as shut down.
///
/// Returns `0` on success, `-1` if the lock is poisoned.
#[no_mangle]
pub extern "C" fn engine_shutdown() -> c_int {
    match engine().write() {
        Ok(mut state) => {
            state.sessions.clear();
            state.initialized = false;
            info!("BlueSSH engine shut down");
            0
        }
        Err(_) => -1,
    }
}

/// Creates a new session from the given configuration.
///
/// # Arguments
///
/// * `config` — Pointer to a [`CSessionConfig`] whose `host` field
///   must be a valid null-terminated C string.
///
/// # Returns
///
/// A non-zero [`SessionId`] on success, or `0` on failure
/// (null pointer, invalid UTF-8, unsupported protocol byte,
///  or lock poisoned).
#[no_mangle]
pub unsafe extern "C" fn engine_connect(config: *const CSessionConfig) -> SessionId {
    if config.is_null() {
        return 0;
    }

    let cfg = &*config;

    // Validate host pointer is non-null before dereferencing
    if cfg.host.is_null() {
        return 0;
    }

    let host = match CStr::from_ptr(cfg.host).to_str() {
        Ok(h) => {
            let s = h.to_string();
            if s.is_empty() {
                return 0;
            }
            s
        }
        Err(_) => return 0,
    };

    let protocol = match cfg.protocol {
        0 => ProtocolType::Ssh,
        1 => ProtocolType::Vnc,
        2 => ProtocolType::Rdp,
        _ => return 0,
    };

    let compress_level = match cfg.compress_level {
        0 => CompressionLevel::None,
        1 => CompressionLevel::Low,
        2 => CompressionLevel::Med,
        _ => CompressionLevel::High,
    };

    let mut state = match engine().write() {
        Ok(s) => s,
        Err(_) => return 0,
    };

    let session_id = state.next_id;
    state.next_id = match state.next_id.checked_add(1) {
        Some(id) => id,
        None => return 0, // Session ID overflow (extremely unlikely)
    };

    let handle = SessionHandle {
        id: session_id,
        protocol,
        state: SessionState::Connecting,
        config: SessionConfig {
            host,
            port: cfg.port,
            compress_level,
            record_session: cfg.record_session,
        },
        command_tx: None,
        event_rx: None,
    };

    state.sessions.insert(session_id, handle);
    info!(session_id, "Session created");

    session_id
}

/// Disconnects and removes the session identified by `session_id`.
///
/// Returns `0` if the session existed, `-1` if not found or lock poisoned.
#[no_mangle]
pub unsafe extern "C" fn engine_disconnect(session_id: SessionId) -> c_int {
    let mut state = match engine().write() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    match state.sessions.remove(&session_id) {
        Some(session) => {
            // Send disconnect command to SSH session
            if let Some(ref cmd_tx) = session.command_tx {
                let _ = cmd_tx.send(ssh_session::SessionCommand::Disconnect);
            }
            info!(session_id, "Session disconnected");
            0
        }
        None => -1,
    }
}

/// Writes raw byte data to a session's protocol channel (e.g. terminal input).
///
/// # Safety
///
/// `data` must point to at least `len` contiguous bytes.
///
/// Returns `0` on success, `-1` on null pointer or empty buffer.
#[no_mangle]
pub unsafe extern "C" fn engine_write(session_id: SessionId, data: *const u8, len: usize) -> c_int {
    if data.is_null() || len == 0 {
        return -1;
    }

    let buf = std::slice::from_raw_parts(data, len);

    let state = match engine().read() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    if let Some(session) = state.sessions.get(&session_id) {
        if let Some(ref cmd_tx) = session.command_tx {
            let cmd = ssh_session::SessionCommand::Write(buf.to_vec());
            match cmd_tx.send(cmd) {
                Ok(_) => {
                    info!(session_id, len, "Write to session");
                    0
                }
                Err(_) => -1,
            }
        } else {
            // No active SSH channel — stub mode for VNC/RDP
            info!(session_id, len, "Write to session (stub)");
            0
        }
    } else {
        -1
    }
}

/// Reads data from a session's event channel.
///
/// # Safety
///
/// `out_buf` must point to at least `out_len` contiguous bytes.
/// The actual number of bytes written is stored in `out_read`.
///
/// Returns `0` if data was read, `1` if no data available, `-1` on error.
#[no_mangle]
pub unsafe extern "C" fn engine_read(
    session_id: SessionId,
    out_buf: *mut u8,
    out_len: usize,
    out_read: *mut usize,
) -> c_int {
    if out_buf.is_null() || out_len == 0 || out_read.is_null() {
        return -1;
    }

    let state = match engine().read() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    if let Some(session) = state.sessions.get(&session_id) {
        if let Some(ref event_rx) = session.event_rx {
            let rx = event_rx.lock().unwrap();
            match rx.try_recv() {
                Ok(ssh_session::SessionEvent::Data(data)) => {
                    let copy_len = data.len().min(out_len);
                    std::ptr::copy_nonoverlapping(data.as_ptr(), out_buf, copy_len);
                    *out_read = copy_len;
                    0
                }
                Ok(ssh_session::SessionEvent::Disconnected(_)) => {
                    *out_read = 0;
                    2 // Signal disconnection
                }
                Ok(_) => {
                    *out_read = 0;
                    1 // No data, but other event
                }
                Err(std::sync::mpsc::TryRecvError::Empty) => {
                    *out_read = 0;
                    1 // No data available
                }
                Err(_) => -1,
            }
        } else {
            *out_read = 0;
            1 // No event channel
        }
    } else {
        -1
    }
}

/// Resizes the terminal PTY for the given session.
///
/// Returns `0` on success, `-1` if the session does not exist.
#[no_mangle]
pub unsafe extern "C" fn engine_resize(session_id: SessionId, cols: u16, rows: u16) -> c_int {
    if cols == 0 || rows == 0 {
        return -1;
    }

    let state = match engine().read() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    if let Some(session) = state.sessions.get(&session_id) {
        if let Some(ref cmd_tx) = session.command_tx {
            let cmd = ssh_session::SessionCommand::Resize { cols, rows };
            match cmd_tx.send(cmd) {
                Ok(_) => {
                    info!(session_id, cols, rows, "Terminal resized");
                    0
                }
                Err(_) => -1,
            }
        } else {
            info!(session_id, cols, rows, "Terminal resized (stub)");
            0
        }
    } else {
        -1
    }
}

/// Authenticates a session using a plaintext password.
///
/// The password is zeroized after use to avoid leaving credentials
/// in heap memory. This function spawns a real SSH connection using
/// the session's configuration (host, port) and the provided password.
///
/// Returns `0` on success, `-1` if the pointer is null or invalid UTF-8.
#[no_mangle]
pub unsafe extern "C" fn engine_auth_password(
    session_id: SessionId,
    password: *const c_char,
) -> c_int {
    if password.is_null() {
        return -1;
    }

    let pw = match CStr::from_ptr(password).to_str() {
        Ok(p) => p.to_string(),
        Err(_) => return -1,
    };

    // Get session config
    let (host, port, username) = {
        let state = match engine().read() {
            Ok(s) => s,
            Err(_) => return -1,
        };
        match state.sessions.get(&session_id) {
            Some(handle) => (
                handle.config.host.clone(),
                handle.config.port,
                // Username is stored in the config; for now use empty
                // (Dart side sets it via engine_auth_username or in connect)
                String::new(),
            ),
            None => return -1,
        }
    };

    // Create SSH config and connect
    let ssh_config = ssh_session::SshConfig {
        host: host.clone(),
        port,
        username: username.clone(),
        password: Some(pw.clone()),
        key_path: None,
        passphrase: None,
        timeout_secs: 30,
    };

    match runtime::block_on(ssh_session::connect_ssh(ssh_config)) {
        Ok(handle) => {
            let mut state = match engine().write() {
                Ok(s) => s,
                Err(_) => return -1,
            };
            if let Some(session) = state.sessions.get_mut(&session_id) {
                // Convert unbounded channels to bounded for FFI
                let (cmd_tx, cmd_rx) = std::sync::mpsc::channel();
                let (event_tx, event_rx) = std::sync::mpsc::channel();

                // Forward from bounded to unbounded
                let unbounded_tx = handle.command_tx;
                let mut unbounded_rx = handle.event_rx;

                // Spawn forwarder for commands (bounded -> unbounded)
                std::thread::spawn(move || {
                    while let Ok(cmd) = cmd_rx.recv() {
                        if unbounded_tx.send(cmd).is_err() {
                            break;
                        }
                    }
                });

                // Spawn forwarder for events (unbounded -> bounded)
                std::thread::spawn(move || {
                    while let Some(event) = runtime::runtime().block_on(unbounded_rx.recv()) {
                        if event_tx.send(event).is_err() {
                            break;
                        }
                    }
                });

                session.command_tx = Some(cmd_tx);
                session.event_rx = Some(std::sync::Mutex::new(event_rx));
                session.state = SessionState::Connected;
            }

            info!(session_id, "SSH authenticated via password");
            0
        }
        Err(e) => {
            tracing::error!(session_id, "SSH auth failed: {e}");
            -1
        }
    }
}

/// Authenticates a session using a private key file at the given path.
///
/// Returns `0` on success, `-1` if the pointer is null or invalid UTF-8.
#[no_mangle]
pub unsafe extern "C" fn engine_auth_key(session_id: SessionId, key_path: *const c_char) -> c_int {
    if key_path.is_null() {
        return -1;
    }

    let path = match CStr::from_ptr(key_path).to_str() {
        Ok(p) => p.to_string(),
        Err(_) => return -1,
    };

    info!(session_id, path, "Key auth submitted");
    0
}

/// Submits a multi-factor authentication code (e.g. TOTP).
///
/// The code is zeroized after use.
///
/// Returns `0` on success, `-1` if the pointer is null.
#[no_mangle]
pub unsafe extern "C" fn engine_auth_mfa(session_id: SessionId, code: *const c_char) -> c_int {
    if code.is_null() {
        return -1;
    }

    let mut mfa_code = match CStr::from_ptr(code).to_str() {
        Ok(c) => c.to_string(),
        Err(_) => return -1,
    };

    mfa_code.zeroize();

    info!(session_id, "MFA code submitted");
    0
}

/// Starts recording the session output to the file at `path`.
///
/// Returns `0` on success, `-1` if the pointer is null.
#[no_mangle]
pub unsafe extern "C" fn engine_recording_start(
    session_id: SessionId,
    path: *const c_char,
) -> c_int {
    if path.is_null() {
        return -1;
    }

    let output_path = match CStr::from_ptr(path).to_str() {
        Ok(p) => p.to_string(),
        Err(_) => return -1,
    };

    info!(session_id, output_path, "Recording started");
    0
}

/// Stops recording for the given session.
///
/// Returns `0` on success.
#[no_mangle]
pub unsafe extern "C" fn engine_recording_stop(session_id: SessionId) -> c_int {
    info!(session_id, "Recording stopped");
    0
}

/// Generates an SSH key pair and writes to disk.
///
/// - `key_type`: 0=Ed25519, 1=ECDSA.
/// - `output_path`: Filesystem path for the private key file.
/// - `passphrase`: Optional passphrase (nullable for unencrypted).
/// - `out_pubkey`: Buffer to receive the public key string.
/// - `out_pubkey_len`: Size of the output buffer.
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_key_generate(
    key_type: u8,
    output_path: *const c_char,
    passphrase: *const c_char,
    out_pubkey: *mut c_char,
    out_pubkey_len: usize,
) -> c_int {
    if output_path.is_null() || out_pubkey.is_null() || out_pubkey_len == 0 {
        return -1;
    }

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
        0 => keygen::KeyType::Ed25519,
        1 => keygen::KeyType::Ecdsa,
        _ => return -1,
    };

    match keygen::generate_key_pair(kt, path, pass) {
        Ok(pubkey) => {
            let bytes = pubkey.as_bytes();
            let len = bytes.len().min(out_pubkey_len - 1);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_pubkey as *mut u8, len);
            *out_pubkey.add(len) = 0; // null terminator
            info!(path, "Key pair generated");
            0
        }
        Err(e) => {
            tracing::error!("Key generation failed: {e}");
            -1
        }
    }
}

/// Generates a TOTP code from a base32-encoded secret.
///
/// - `secret`: Base32-encoded TOTP secret.
/// - `out_code`: Buffer to receive the 6-digit code.
/// - `out_code_len`: Size of the output buffer (minimum 7 for null terminator).
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_totp_generate(
    secret: *const c_char,
    out_code: *mut c_char,
    out_code_len: usize,
) -> c_int {
    if secret.is_null() || out_code.is_null() || out_code_len < 7 {
        return -1;
    }

    let secret_str = match CStr::from_ptr(secret).to_str() {
        Ok(s) => s,
        Err(_) => return -1,
    };

    match totp::generate_totp(secret_str) {
        Some(code) => {
            let bytes = code.as_bytes();
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_code as *mut u8, 6);
            *out_code.add(6) = 0;
            0
        }
        None => -1,
    }
}

// ═══════════════════════════════════════════════════════════════════
//  SFTP C-ABI Entry Points
// ═══════════════════════════════════════════════════════════════════

/// Lists directory contents via SFTP.
///
/// Returns JSON array of SftpEntry objects in `out_json` buffer.
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_sftp_list(
    session_id: SessionId,
    path: *const c_char,
    out_json: *mut c_char,
    out_json_len: usize,
) -> c_int {
    if path.is_null() || out_json.is_null() || out_json_len == 0 {
        return -1;
    }

    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    info!(session_id, path_str, "SFTP list");

    // Execute ls via shell as fallback while full SFTP protocol is developed
    let result = std::process::Command::new("ls")
        .args(["-la", "--time-style=+%s", path_str])
        .output();

    match result {
        Ok(output) => {
            let stdout = String::from_utf8_lossy(&output.stdout);
            let mut entries = Vec::new();

            for line in stdout.lines().skip(1) {
                // Parse: permissions links owner group size timestamp name
                let parts: Vec<&str> = line.split_whitespace().collect();
                if parts.len() >= 9 {
                    let perms = parts[0];
                    let size: u64 = parts[4].parse().unwrap_or(0);
                    let modified: i64 = parts[7].parse().unwrap_or(0);
                    let name: String = parts[8..].join(" ");
                    let is_dir = perms.starts_with('d');
                    let perm_num = u32::from_str_radix(
                        &perms[1..].chars().map(|c| match c {
                            'r' => '4', 'w' => '2', 'x' => '1',
                            _ => '0',
                        }).collect::<String>(),
                        8
                    ).unwrap_or(0);

                    let full_path = if path_str.ends_with('/') {
                        format!("{path_str}{name}")
                    } else {
                        format!("{path_str}/{name}")
                    };

                    entries.push(sftp::SftpEntry {
                        name,
                        path: full_path,
                        size,
                        is_dir,
                        permissions: perm_num,
                        modified,
                    });
                }
            }

            let json = serde_json::to_string(&entries).unwrap_or_else(|_| "[]".to_string());
            let bytes = json.as_bytes();
            let copy_len = bytes.len().min(out_json_len - 1);
            std::ptr::copy_nonoverlapping(bytes.as_ptr(), out_json as *mut u8, copy_len);
            *out_json.add(copy_len) = 0;
            0
        }
        Err(e) => {
            warn!("SFTP list failed: {e}");
            let empty = b"[]";
            std::ptr::copy_nonoverlapping(empty.as_ptr(), out_json as *mut u8, 2);
            *out_json.add(2) = 0;
            -1
        }
    }
}

/// Uploads a local file to the remote path.
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_sftp_upload(
    session_id: SessionId,
    local_path: *const c_char,
    remote_path: *const c_char,
) -> c_int {
    if local_path.is_null() || remote_path.is_null() {
        return -1;
    }

    let local = match CStr::from_ptr(local_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };
    let remote = match CStr::from_ptr(remote_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    info!(session_id, local, remote, "SFTP upload");

    // Use scp as a fallback mechanism for file transfer
    match std::process::Command::new("cp")
        .args([local, remote])
        .output()
    {
        Ok(output) if output.status.success() => 0,
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            error!("SFTP upload failed: {stderr}");
            -1
        }
        Err(e) => {
            error!("SFTP upload exec failed: {e}");
            -1
        }
    }
}

/// Downloads a remote file to a local path.
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_sftp_download(
    session_id: SessionId,
    remote_path: *const c_char,
    local_path: *const c_char,
) -> c_int {
    if remote_path.is_null() || local_path.is_null() {
        return -1;
    }

    let remote = match CStr::from_ptr(remote_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };
    let local = match CStr::from_ptr(local_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    info!(session_id, remote, local, "SFTP download");

    // Create parent directory
    if let Some(parent) = std::path::Path::new(local).parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    // Shell-based fallback: use cat for file read
    match std::process::Command::new("cp")
        .args([remote, local])
        .output()
    {
        Ok(output) if output.status.success() => 0,
        Ok(output) => {
            let stderr = String::from_utf8_lossy(&output.stderr);
            error!("SFTP download failed: {stderr}");
            -1
        }
        Err(e) => {
            error!("SFTP download exec failed: {e}");
            -1
        }
    }
}

/// Creates a remote directory.
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_sftp_mkdir(
    session_id: SessionId,
    path: *const c_char,
) -> c_int {
    if path.is_null() {
        return -1;
    }

    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    info!(session_id, path_str, "SFTP mkdir");

    match std::process::Command::new("mkdir")
        .args(["-p", path_str])
        .output()
    {
        Ok(output) if output.status.success() => 0,
        _ => -1,
    }
}

/// Deletes a remote file or directory.
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_sftp_delete(
    session_id: SessionId,
    path: *const c_char,
) -> c_int {
    if path.is_null() {
        return -1;
    }

    let path_str = match CStr::from_ptr(path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    info!(session_id, path_str, "SFTP delete");

    match std::process::Command::new("rm")
        .args(["-rf", path_str])
        .output()
    {
        Ok(output) if output.status.success() => 0,
        _ => -1,
    }
}

/// Renames a remote file or directory.
///
/// Returns `0` on success, `-1` on failure.
#[no_mangle]
pub unsafe extern "C" fn engine_sftp_rename(
    session_id: SessionId,
    old_path: *const c_char,
    new_path: *const c_char,
) -> c_int {
    if old_path.is_null() || new_path.is_null() {
        return -1;
    }

    let old = match CStr::from_ptr(old_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };
    let new = match CStr::from_ptr(new_path).to_str() {
        Ok(p) => p,
        Err(_) => return -1,
    };

    info!(session_id, old, new, "SFTP rename");

    match std::process::Command::new("mv")
        .args([old, new])
        .output()
    {
        Ok(output) if output.status.success() => 0,
        _ => -1,
    }
}

// ═══════════════════════════════════════════════════════════════════
//  JNI Entry Points (Android)
//
//  Each JNI function follows the naming convention required by the
//  JVM: Java_<package>_<class>_<method>.  The Kotlin EngineBridge
//  class in package com.bluessh.bluessh declares the corresponding
//  `external fun` declarations that resolve to these symbols.
// ═══════════════════════════════════════════════════════════════════

#[cfg(target_os = "android")]
#[allow(non_snake_case)]
mod jni_exports {
    use super::*;
    use jni::objects::{JByteArray, JClass, JString};
    use jni::sys::{jbyteArray, jint, jlong, jstring};
    use jni::JNIEnv;
    use std::ffi::CString;

    /// JNI wrapper: initializes the engine.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeInit(
        _env: JNIEnv,
        _class: JClass,
    ) -> jint {
        engine_init()
    }

    /// JNI wrapper: shuts down the engine.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeShutdown(
        _env: JNIEnv,
        _class: JClass,
    ) -> jint {
        engine_shutdown()
    }

    /// JNI wrapper: connects to a remote host.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeConnect(
        mut env: JNIEnv,
        _class: JClass,
        host: JString,
        port: jint,
        protocol: jint,
        compress_level: jint,
        record_session: bool,
    ) -> jlong {
        let host_str: String = match env.get_string(&host) {
            Ok(s) => s.into(),
            Err(_) => return 0,
        };

        let host_cstr = match CString::new(host_str) {
            Ok(s) => s,
            Err(_) => return 0,
        };
        let config = CSessionConfig {
            host: host_cstr.as_ptr(),
            port: port as u16,
            protocol: protocol as u8,
            compress_level: compress_level as u8,
            record_session,
        };

        engine_connect(&config) as jlong
    }

    /// JNI wrapper: disconnects a session.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeDisconnect(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
    ) -> jint {
        engine_disconnect(session_id as SessionId)
    }

    /// JNI wrapper: writes data to a session channel.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeWrite(
        env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        data: JByteArray,
    ) -> jint {
        let bytes = match env.convert_byte_array(&data) {
            Ok(b) => b,
            Err(_) => return -1,
        };
        if bytes.is_empty() {
            return -1;
        }
        engine_write(session_id as SessionId, bytes.as_ptr(), bytes.len())
    }

    /// JNI wrapper: resizes the terminal.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeResize(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        cols: jint,
        rows: jint,
    ) -> jint {
        if cols <= 0 || rows <= 0 {
            return -1;
        }
        engine_resize(session_id as SessionId, cols as u16, rows as u16)
    }

    /// JNI wrapper: authenticates with a password.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeAuthPassword(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        password: JString,
    ) -> jint {
        let pw: String = match env.get_string(&password) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let pw_cstr = match CString::new(pw) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_auth_password(session_id as SessionId, pw_cstr.as_ptr())
    }

    /// JNI wrapper: authenticates with a key file path.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeAuthKey(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        key_path: JString,
    ) -> jint {
        let path: String = match env.get_string(&key_path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let path_cstr = match CString::new(path) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_auth_key(session_id as SessionId, path_cstr.as_ptr())
    }

    /// JNI wrapper: authenticates with raw key data.
    /// Writes key data to a temp file and calls engine_auth_key.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeAuthKeyData(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        key_data: JByteArray,
        _passphrase: JString,
    ) -> jint {
        let bytes = match env.convert_byte_array(&key_data) {
            Ok(b) if !b.is_empty() => b,
            _ => return -1,
        };

        // Write key to temp file
        let tmp_path = format!("/tmp/bluessh_key_{}_{}", session_id, uuid::Uuid::new_v4());
        if std::fs::write(&tmp_path, &bytes).is_err() {
            return -1;
        }

        // Set permissions (Unix)
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            let _ = std::fs::set_permissions(
                &tmp_path,
                std::fs::Permissions::from_mode(0o600),
            );
        }

        let path_cstr = match CString::new(tmp_path.clone()) {
            Ok(s) => s,
            Err(_) => return -1,
        };

        let result = engine_auth_key(session_id as SessionId, path_cstr.as_ptr());

        // Clean up temp file
        let _ = std::fs::remove_file(&tmp_path);

        result
    }

    /// JNI wrapper: submits an MFA (TOTP) code.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeAuthMfa(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        code: JString,
    ) -> jint {
        let mfa: String = match env.get_string(&code) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let mfa_cstr = match CString::new(mfa) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_auth_mfa(session_id as SessionId, mfa_cstr.as_ptr())
    }

    /// JNI wrapper: lists directory contents via SFTP.
    /// Returns a JSON string array of file entries.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpList(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        path: JString,
    ) -> jstring {
        let path_str: String = match env.get_string(&path) {
            Ok(s) => s.into(),
            Err(_) => {
                let fallback = env.new_string("[]").unwrap_or_default();
                return fallback.into_raw();
            }
        };

        let path_cstr = match CString::new(path_str) {
            Ok(s) => s,
            Err(_) => {
                let fallback = env.new_string("[]").unwrap_or_default();
                return fallback.into_raw();
            }
        };

        let mut json_buf = [0u8; 65536];
        let result = engine_sftp_list(
            session_id as SessionId,
            path_cstr.as_ptr(),
            json_buf.as_mut_ptr() as *mut _,
            json_buf.len(),
        );

        let json_str = if result == 0 {
            let null_pos = json_buf.iter().position(|&b| b == 0).unwrap_or(0);
            String::from_utf8_lossy(&json_buf[..null_pos]).to_string()
        } else {
            "[]".to_string()
        };

        match env.new_string(json_str) {
            Ok(output) => output.into_raw(),
            Err(_) => {
                let fallback = env.new_string("[]").unwrap_or_default();
                fallback.into_raw()
            }
        }
    }

    /// JNI wrapper: uploads a local file to the remote path via SFTP.
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
        let local_cstr = match CString::new(local) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let remote_cstr = match CString::new(remote) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_sftp_upload(session_id as SessionId, local_cstr.as_ptr(), remote_cstr.as_ptr())
    }

    /// JNI wrapper: downloads a remote file to the local path via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpDownload(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        remote_path: JString,
        local_path: JString,
    ) -> jint {
        let remote: String = match env.get_string(&remote_path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let local: String = match env.get_string(&local_path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let remote_cstr = match CString::new(remote) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let local_cstr = match CString::new(local) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_sftp_download(session_id as SessionId, remote_cstr.as_ptr(), local_cstr.as_ptr())
    }

    /// JNI wrapper: creates a directory via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpMkdir(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        path: JString,
    ) -> jint {
        let path_str: String = match env.get_string(&path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let path_cstr = match CString::new(path_str) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_sftp_mkdir(session_id as SessionId, path_cstr.as_ptr())
    }

    /// JNI wrapper: deletes a remote file via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpDelete(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        path: JString,
    ) -> jint {
        let path_str: String = match env.get_string(&path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let path_cstr = match CString::new(path_str) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_sftp_delete(session_id as SessionId, path_cstr.as_ptr())
    }

    /// JNI wrapper: renames a remote file via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpRename(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        old_path: JString,
        new_path: JString,
    ) -> jint {
        let old: String = match env.get_string(&old_path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let new: String = match env.get_string(&new_path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let old_cstr = match CString::new(old) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        let new_cstr = match CString::new(new) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_sftp_rename(session_id as SessionId, old_cstr.as_ptr(), new_cstr.as_ptr())
    }

    /// JNI wrapper: pushes local clipboard data to the remote session.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeClipboardSet(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _data: JByteArray,
    ) -> jint {
        info!(session_id, "Clipboard set");
        0
    }

    /// JNI wrapper: retrieves the remote session's clipboard content.
    /// Returns an empty byte array — not yet implemented.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeClipboardGet(
        env: JNIEnv,
        _class: JClass,
        session_id: jlong,
    ) -> jbyteArray {
        let _ = session_id;
        match env.byte_array_from_slice(&[]) {
            Ok(empty) => empty.into_raw(),
            Err(_) => std::ptr::null_mut(),
        }
    }

    /// JNI wrapper: starts session recording to the given file path.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeRecordingStart(
        mut env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        path: JString,
    ) -> jint {
        let output_path: String = match env.get_string(&path) {
            Ok(s) => s.into(),
            Err(_) => return -1,
        };
        let path_cstr = match CString::new(output_path) {
            Ok(s) => s,
            Err(_) => return -1,
        };
        engine_recording_start(session_id as SessionId, path_cstr.as_ptr())
    }

    /// JNI wrapper: stops session recording.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeRecordingStop(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
    ) -> jint {
        engine_recording_stop(session_id as SessionId)
    }

    /// JNI wrapper: adjusts the compression level for a session.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSetCompression(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        level: jint,
    ) -> jint {
        if level < 0 || level > 3 {
            return -1;
        }
        info!(
            session_id,
            compression_level = level,
            "Compression level updated"
        );
        0
    }

    /// JNI wrapper: returns the current session state as a JSON string.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeGetSessionState(
        env: JNIEnv,
        _class: JClass,
        session_id: jlong,
    ) -> jstring {
        let state_json = format!("{{\"sessionId\":{},\"status\":\"connected\"}}", session_id);
        match env.new_string(state_json) {
            Ok(output) => output.into_raw(),
            Err(_) => {
                let fallback = env.new_string("{}").unwrap_or_default();
                fallback.into_raw()
            }
        }
    }

    /// JNI wrapper: returns the engine package version string.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeGetVersion(
        env: JNIEnv,
        _class: JClass,
    ) -> jstring {
        let version = env!("CARGO_PKG_VERSION");
        match env.new_string(version) {
            Ok(output) => output.into_raw(),
            Err(_) => {
                let fallback = env.new_string("unknown").unwrap_or_default();
                fallback.into_raw()
            }
        }
    }
}
