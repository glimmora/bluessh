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
import '../models/host_profile.dart' show ProtocolType;

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

typedef EngineKeyGenerateC = Int32 Function(
    Uint8 keyType, Pointer<Utf8> outputPath, Pointer<Utf8> passphrase,
    Pointer<Utf8> outPubkey, Size outPubkeyLen);
typedef EngineKeyGenerate = int Function(
    int keyType, Pointer<Utf8> outputPath, Pointer<Utf8> passphrase,
    Pointer<Utf8> outPubkey, int outPubkeyLen);

// ═══════════════════════════════════════════════════════════════════
//  Protocol Mapping & State Enums
// ═══════════════════════════════════════════════════════════════════

/// Maps the UI [ProtocolType] to the engine wire-format integer.
///
/// The Rust engine uses: Ssh=0, Vnc=1, Rdp=2.
/// SFTP is an SSH sub-channel, so it maps to Ssh (0).
int protocolToEngineValue(ProtocolType p) {
  switch (p) {
    case ProtocolType.ssh:
    case ProtocolType.sftp:
      return 0;
    case ProtocolType.vnc:
      return 1;
    case ProtocolType.rdp:
      return 2;
  }
}

/// Connection state as reported through the FFI bridge.
enum FfiConnectionState {
  connecting,
  authenticating,
  connected,
  disconnected,
  error,
}

/// Session state snapshot used by the FFI bridge stream.
class FfiSessionState {
  final int sessionId;
  final FfiConnectionState connectionState;
  final String? errorMessage;

  const FfiSessionState({
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
  late final EngineKeyGenerate _engineKeyGenerate;

  final _stateController = StreamController<FfiSessionState>.broadcast();

  /// Broadcast stream of session state changes.
  Stream<FfiSessionState> get sessionStates => _stateController.stream;

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
    _engineKeyGenerate =
        _engine.lookupFunction<EngineKeyGenerateC, EngineKeyGenerate>('engine_key_generate');
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
    if (host.isEmpty) return 0;

    final config = calloc<CSessionConfig>();
    config.ref.host = host.toNativeUtf8();
    config.ref.port = port;
    config.ref.protocol = protocolToEngineValue(protocol);
    config.ref.compressLevel = compressionLevel;
    config.ref.recordSession = recordSession;

    try {
      final sessionId = _engineConnect(config);
      if (sessionId != 0) {
        _stateController.add(FfiSessionState(
          sessionId: sessionId,
          connectionState: FfiConnectionState.connecting,
        ));
      }
      return sessionId;
    } catch (e) {
      return 0;
    } finally {
      calloc.free(config.ref.host);
      calloc.free(config);
    }
  }

  /// Disconnects the session. Returns `0` on success.
  int disconnect(int sessionId) {
    try {
      final result = _engineDisconnect(sessionId);
      if (result == 0) {
        _stateController.add(FfiSessionState(
          sessionId: sessionId,
          connectionState: FfiConnectionState.disconnected,
        ));
      }
      return result;
    } catch (e) {
      return -1;
    }
  }

  /// Writes a string to the session channel.
  int write(int sessionId, String data) {
    if (data.isEmpty) return -1;
    final bytes = Uint8List.fromList(data.codeUnits);
    final pointer = calloc<Uint8>(bytes.length);
    pointer.asTypedList(bytes.length).setAll(0, bytes);
    try {
      return _engineWrite(sessionId, pointer, bytes.length);
    } catch (e) {
      return -1;
    } finally {
      calloc.free(pointer);
    }
  }

  /// Writes raw bytes to the session channel.
  int writeBytes(int sessionId, Uint8List data) {
    if (data.isEmpty) return -1;
    final pointer = calloc<Uint8>(data.length);
    pointer.asTypedList(data.length).setAll(0, data);
    try {
      return _engineWrite(sessionId, pointer, data.length);
    } catch (e) {
      return -1;
    } finally {
      calloc.free(pointer);
    }
  }

  /// Resizes the terminal to [cols] x [rows].
  int resize(int sessionId, int cols, int rows) {
    if (cols <= 0 || rows <= 0) return -1;
    try {
      return _engineResize(sessionId, cols, rows);
    } catch (e) {
      return -1;
    }
  }

  /// Authenticates with a plaintext password.
  int authPassword(int sessionId, String password) {
    if (password.isEmpty) return -1;
    final pwPtr = password.toNativeUtf8();
    try {
      return _engineAuthPassword(sessionId, pwPtr);
    } catch (e) {
      return -1;
    } finally {
      calloc.free(pwPtr);
    }
  }

  /// Authenticates with an SSH key file at the given path.
  int authKey(int sessionId, String keyPath) {
    if (keyPath.isEmpty) return -1;
    final pathPtr = keyPath.toNativeUtf8();
    try {
      return _engineAuthKey(sessionId, pathPtr);
    } catch (e) {
      return -1;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Submits a multi-factor authentication code.
  int authMfa(int sessionId, String code) {
    if (code.isEmpty) return -1;
    final codePtr = code.toNativeUtf8();
    try {
      return _engineAuthMfa(sessionId, codePtr);
    } catch (e) {
      return -1;
    } finally {
      calloc.free(codePtr);
    }
  }

  /// Starts recording the session to the given output path.
  int startRecording(int sessionId, String outputPath) {
    if (outputPath.isEmpty) return -1;
    final pathPtr = outputPath.toNativeUtf8();
    try {
      return _engineRecordingStart(sessionId, pathPtr);
    } catch (e) {
      return -1;
    } finally {
      calloc.free(pathPtr);
    }
  }

  /// Stops recording the session.
  int stopRecording(int sessionId) {
    try {
      return _engineRecordingStop(sessionId);
    } catch (e) {
      return -1;
    }
  }

  /// Generates an SSH key pair. Returns the public key string or null on failure.
  String? generateKey({
    required int keyType, // 0=Ed25519, 1=ECDSA
    required String outputPath,
    String passphrase = '',
  }) {
    if (outputPath.isEmpty) return null;

    final pathPtr = outputPath.toNativeUtf8();
    final passPtr = passphrase.toNativeUtf8();
    final outBuf = calloc<Utf8>(4096);

    try {
      final result = _engineKeyGenerate(
        keyType, pathPtr, passPtr, outBuf, 4096,
      );
      if (result == 0) {
        return outBuf.toDartString();
      }
      return null;
    } catch (e) {
      return null;
    } finally {
      calloc.free(pathPtr);
      calloc.free(passPtr);
      calloc.free(outBuf);
    }
  }

  /// Closes the state stream and releases the singleton.
  void dispose() {
    _stateController.close();
    _instance = null;
  }
}
