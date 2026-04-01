/// Desktop FFI bridge to the Rust engine (Windows, Linux, macOS).
///
/// Provides the same functional interface as the MethodChannel-based
/// [SessionService] for Android, but communicates with the native
/// engine through dart:ffi for lower latency on desktop platforms.
///
/// This module is not used on Android; the Kotlin EngineBridge
/// handles JNI communication there.
library;

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// ═══════════════════════════════════════════════════════════════════
//  FFI Struct Definitions
// ═══════════════════════════════════════════════════════════════════

/// Mirrors the Rust `CSessionConfig` struct for FFI interop.
base class CSessionConfig extends Struct {
  external Pointer<Utf8> host;

  @Uint16()
  external int port;

  @Uint8()
  external int protocol;

  @Uint8()
  external int compressLevel;

  @Bool()
  external bool recordSession;
}

/// Mirrors the Rust `CTerminalFrame` struct for FFI interop.
base class CTerminalFrame extends Struct {
  external Pointer<Uint8> data;

  @Size()
  external int len;

  @Uint16()
  external int rows;

  @Uint16()
  external int cols;
}

// ═══════════════════════════════════════════════════════════════════
//  Native Function Signatures
// ═══════════════════════════════════════════════════════════════════

typedef EngineInitC = Int32 Function();
typedef EngineInit = int Function();

typedef EngineShutdownC = Int32 Function();
typedef EngineShutdown = int Function();

typedef EngineConnectC = Uint64 Function(Pointer<CSessionConfig> config);
typedef EngineConnect = int Function(Pointer<CSessionConfig> config);

typedef EngineDisconnectC = Int32 Function(Uint64 sessionId);
typedef EngineDisconnect = int Function(int sessionId);

typedef EngineWriteC = Int32 Function(
    Uint64 sessionId, Pointer<Uint8> data, Size len);
typedef EngineWrite = int Function(
    int sessionId, Pointer<Uint8> data, int len);

typedef EngineResizeC = Int32 Function(
    Uint64 sessionId, Uint16 cols, Uint16 rows);
typedef EngineResize = int Function(int sessionId, int cols, int rows);

typedef EngineAuthPasswordC = Int32 Function(
    Uint64 sessionId, Pointer<Utf8> password);
typedef EngineAuthPassword = int Function(
    int sessionId, Pointer<Utf8> password);

typedef EngineAuthKeyC = Int32 Function(
    Uint64 sessionId, Pointer<Utf8> keyPath);
typedef EngineAuthKey = int Function(
    int sessionId, Pointer<Utf8> keyPath);

typedef EngineAuthMfaC = Int32 Function(
    Uint64 sessionId, Pointer<Utf8> code);
typedef EngineAuthMfa = int Function(
    int sessionId, Pointer<Utf8> code);

typedef EngineRecordingStartC = Int32 Function(
    Uint64 sessionId, Pointer<Utf8> path);
typedef EngineRecordingStart = int Function(
    int sessionId, Pointer<Utf8> path);

typedef EngineRecordingStopC = Int32 Function(Uint64 sessionId);
typedef EngineRecordingStop = int Function(int sessionId);

// ═══════════════════════════════════════════════════════════════════
//  Protocol & State Enums
// ═══════════════════════════════════════════════════════════════════

/// Protocol types for the FFI bridge (subset used on desktop).
enum ProtocolType {
  ssh(0),
  vnc(1),
  rdp(2);

  final int value;
  const ProtocolType(this.value);
}

/// Connection state as reported through the FFI bridge.
enum SessionConnectionState {
  connecting,
  authenticating,
  connected,
  disconnected,
  error,
}

/// Session state snapshot used by the FFI bridge stream.
class SessionState {
  final int sessionId;
  final SessionConnectionState connectionState;
  final String? errorMessage;

  const SessionState({
    required this.sessionId,
    required this.connectionState,
    this.errorMessage,
  });
}

// ═══════════════════════════════════════════════════════════════════
//  Engine Bridge (Desktop dart:ffi)
// ═══════════════════════════════════════════════════════════════════

/// Singleton FFI bridge to the native Rust engine.
///
/// Loads the platform-specific shared library on first access and
/// binds all required native functions.  Exposes a stream of
/// [SessionState] changes for UI consumption.
class EngineBridge {
  static EngineBridge? _instance;
  late final DynamicLibrary _engine;

  late final EngineInit _engineInit;
  late final EngineShutdown _engineShutdown;
  late final EngineConnect _engineConnect;
  late final EngineDisconnect _engineDisconnect;
  late final EngineWrite _engineWrite;
  late final EngineResize _engineResize;
  late final EngineAuthPassword _engineAuthPassword;
  late final EngineAuthKey _engineAuthKey;
  late final EngineAuthMfa _engineAuthMfa;
  late final EngineRecordingStart _engineRecordingStart;
  late final EngineRecordingStop _engineRecordingStop;

  final _stateController = StreamController<SessionState>.broadcast();

  /// Broadcast stream of session state changes.
  Stream<SessionState> get sessionStates => _stateController.stream;

  EngineBridge._() {
    _engine = _loadNativeLibrary();
    _bindNativeFunctions();
  }

  /// Returns the singleton bridge instance, creating it on first call.
  factory EngineBridge.instance() {
    return _instance ??= EngineBridge._();
  }

  /// Loads the platform-appropriate shared library.
  static DynamicLibrary _loadNativeLibrary() {
    if (Platform.isWindows) {
      return DynamicLibrary.open('bluessh.dll');
    } else if (Platform.isLinux) {
      return DynamicLibrary.open('libbluessh.so');
    } else if (Platform.isMacOS) {
      return DynamicLibrary.open('libbluessh.dylib');
    }
    throw UnsupportedError(
      'Platform ${Platform.operatingSystem} is not supported',
    );
  }

  /// Binds all native function symbols from the loaded library.
  void _bindNativeFunctions() {
    _engineInit =
        _engine.lookupFunction<EngineInitC, EngineInit>('engine_init');
    _engineShutdown =
        _engine.lookupFunction<EngineShutdownC, EngineShutdown>('engine_shutdown');
    _engineConnect =
        _engine.lookupFunction<EngineConnectC, EngineConnect>('engine_connect');
    _engineDisconnect =
        _engine.lookupFunction<EngineDisconnectC, EngineDisconnect>('engine_disconnect');
    _engineWrite =
        _engine.lookupFunction<EngineWriteC, EngineWrite>('engine_write');
    _engineResize =
        _engine.lookupFunction<EngineResizeC, EngineResize>('engine_resize');
    _engineAuthPassword =
        _engine.lookupFunction<EngineAuthPasswordC, EngineAuthPassword>('engine_auth_password');
    _engineAuthKey =
        _engine.lookupFunction<EngineAuthKeyC, EngineAuthKey>('engine_auth_key');
    _engineAuthMfa =
        _engine.lookupFunction<EngineAuthMfaC, EngineAuthMfa>('engine_auth_mfa');
    _engineRecordingStart =
        _engine.lookupFunction<EngineRecordingStartC, EngineRecordingStart>('engine_recording_start');
    _engineRecordingStop =
        _engine.lookupFunction<EngineRecordingStopC, EngineRecordingStop>('engine_recording_stop');
  }

  // ── Public API ─────────────────────────────────────────────────

  /// Initializes the native engine. Returns `0` on success.
  int init() => _engineInit();

  /// Shuts down the native engine. Returns `0` on success.
  int shutdown() => _engineShutdown();

  /// Connects to a remote host. Returns the session ID or `0` on failure.
  int connect({
    required String host,
    required int port,
    ProtocolType protocol = ProtocolType.ssh,
    int compressionLevel = 2,
    bool recordSession = false,
  }) {
    final config = calloc<CSessionConfig>();
    config.ref.host = host.toNativeUtf8();
    config.ref.port = port;
    config.ref.protocol = protocol.value;
    config.ref.compressLevel = compressionLevel;
    config.ref.recordSession = recordSession;

    try {
      final sessionId = _engineConnect(config);
      if (sessionId != 0) {
        _stateController.add(SessionState(
          sessionId: sessionId,
          connectionState: SessionConnectionState.connecting,
        ));
      }
      return sessionId;
    } finally {
      calloc.free(config.ref.host);
      calloc.free(config);
    }
  }

  /// Disconnects the session. Returns `0` on success.
  int disconnect(int sessionId) {
    final result = _engineDisconnect(sessionId);
    if (result == 0) {
      _stateController.add(SessionState(
        sessionId: sessionId,
        connectionState: SessionConnectionState.disconnected,
      ));
    }
    return result;
  }

  /// Writes a string to the session channel.
  int write(int sessionId, String data) {
    final bytes = Uint8List.fromList(data.codeUnits);
    final pointer = calloc<Uint8>(bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    try {
      return _engineWrite(sessionId, pointer, bytes.length);
    } finally {
      calloc.free(pointer);
    }
  }

  /// Writes raw bytes to the session channel.
  int writeBytes(int sessionId, Uint8List data) {
    final pointer = calloc<Uint8>(data.length);
    pointer.asTypedList(data.length).setAll(0, data);
    try {
      return _engineWrite(sessionId, pointer, data.length);
    } finally {
      calloc.free(pointer);
    }
  }

  /// Resizes the terminal to [cols] x [rows].
  int resize(int sessionId, int cols, int rows) {
    return _engineResize(sessionId, cols, rows);
  }

  /// Authenticates with a plaintext password.
  int authPassword(int sessionId, String password) {
    final pwPtr = password.toNativeUtf8();
    try {
      return _engineAuthPassword(sessionId, pwPtr);
    } finally {
      calloc.free(pwPtr);
    }
  }

  /// Authenticates with an SSH key file at the given path.
  int authKey(int sessionId, String keyPath) {
    final pathPtr = keyPath.toNativeUtf8();
    try {
      return _engineAuthKey(sessionId, pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Submits a multi-factor authentication code.
  int authMfa(int sessionId, String code) {
    final codePtr = code.toNativeUtf8();
    try {
      return _engineAuthMfa(sessionId, codePtr);
    } finally {
      calloc.free(codePtr);
    }
  }

  /// Starts recording the session to the given output path.
  int startRecording(int sessionId, String outputPath) {
    final pathPtr = outputPath.toNativeUtf8();
    try {
      return _engineRecordingStart(sessionId, pathPtr);
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Stops recording the session.
  int stopRecording(int sessionId) {
    return _engineRecordingStop(sessionId);
  }

  /// Closes the state stream and releases the singleton.
  void dispose() {
    _stateController.close();
    _instance = null;
  }
}
