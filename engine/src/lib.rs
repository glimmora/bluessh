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
#![allow(unused_variables)]

use std::collections::HashMap;
use std::ffi::{CStr, CString};
use std::os::raw::{c_char, c_int};
use std::sync::{OnceLock, RwLock};

use serde::{Deserialize, Serialize};
use tracing::info;
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
#[allow(dead_code)]
struct SessionHandle {
    id: SessionId,
    protocol: ProtocolType,
    state: SessionState,
    config: SessionConfig,
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
    match engine().write() {
        Ok(mut state) => match state.sessions.remove(&session_id) {
            Some(_) => {
                info!(session_id, "Session disconnected");
                0
            }
            None => -1,
        },
        Err(_) => -1,
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

    let _buf = std::slice::from_raw_parts(data, len);
    info!(session_id, len, "Write to session");
    0
}

/// Resizes the terminal PTY for the given session.
///
/// Returns `0` on success.
#[no_mangle]
pub unsafe extern "C" fn engine_resize(session_id: SessionId, cols: u16, rows: u16) -> c_int {
    info!(session_id, cols, rows, "Terminal resized");
    0
}

/// Authenticates a session using a plaintext password.
///
/// The password is zeroized after use to avoid leaving credentials
/// in heap memory.
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

    let mut pw = match CStr::from_ptr(password).to_str() {
        Ok(p) => p.to_string(),
        Err(_) => return -1,
    };

    // TODO: Forward to SSH password authentication handler.
    pw.zeroize();

    info!(session_id, "Password auth submitted");
    0
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

    /// JNI wrapper: authenticates with raw key data and a passphrase.
    /// Not yet implemented — placeholder returns 0.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeAuthKeyData(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _key_data: JByteArray,
        _passphrase: JString,
    ) -> jint {
        // TODO: Deserialize key bytes and forward to SSH key auth handler.
        info!(session_id, "Key data auth attempted");
        0
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
    /// Not yet implemented — placeholder returns "[]".
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpList(
        env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _path: JString,
    ) -> jstring {
        let _ = session_id;
        let empty_json = "[]".to_string();
        match env.new_string(empty_json) {
            Ok(output) => output.into_raw(),
            Err(_) => {
                // Return empty string on failure — JNI callers expect non-null
                let fallback = env.new_string("").unwrap_or_default();
                fallback.into_raw()
            }
        }
    }

    /// JNI wrapper: uploads a local file to the remote path via SFTP.
    /// Not yet implemented — placeholder returns 0.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpUpload(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _local_path: JString,
        _remote_path: JString,
    ) -> jint {
        info!(session_id, "SFTP upload initiated");
        0
    }

    /// JNI wrapper: downloads a remote file to the local path via SFTP.
    /// Not yet implemented — placeholder returns 0.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpDownload(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _remote_path: JString,
        _local_path: JString,
    ) -> jint {
        info!(session_id, "SFTP download initiated");
        0
    }

    /// JNI wrapper: creates a directory via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpMkdir(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _path: JString,
    ) -> jint {
        info!(session_id, "SFTP mkdir");
        0
    }

    /// JNI wrapper: deletes a remote file via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpDelete(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _path: JString,
    ) -> jint {
        info!(session_id, "SFTP delete");
        0
    }

    /// JNI wrapper: renames a remote file via SFTP.
    #[no_mangle]
    pub unsafe extern "C" fn Java_com_bluessh_bluessh_EngineBridge_nativeSftpRename(
        _env: JNIEnv,
        _class: JClass,
        session_id: jlong,
        _old_path: JString,
        _new_path: JString,
    ) -> jint {
        info!(session_id, "SFTP rename");
        0
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
