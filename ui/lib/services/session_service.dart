/// Session lifecycle manager.
///
/// Provides the primary interface between the Flutter UI and the native
/// Rust engine.  Manages connection lifecycle, authentication, terminal
/// I/O, SFTP operations, clipboard synchronization, keep-alive timers,
/// and automatic reconnection with exponential backoff.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/host_profile.dart';
import '../models/session_state.dart';
import 'engine_bridge.dart' show protocolToEngineValue;

/// Riverpod provider for the singleton [SessionService] instance.
final sessionServiceProvider = Provider<SessionService>((ref) {
  final service = SessionService();
  ref.onDispose(() => service.dispose());
  return service;
});

/// Riverpod provider tracking all active session states, keyed by session ID.
final activeSessionsProvider =
    StateNotifierProvider<ActiveSessionsNotifier, Map<int, SessionState>>(
  (ref) => ActiveSessionsNotifier(),
);

/// Riverpod provider tracking file transfer progress, keyed by transfer ID.
final transferProgressProvider =
    StateNotifierProvider<TransferProgressNotifier, Map<String, TransferProgress>>(
  (ref) => TransferProgressNotifier(),
);

/// Interval between keep-alive pings sent to the remote server.
/// Default 30s — overridden by user's 'keepalive_interval' setting.
Duration _keepaliveInterval = const Duration(seconds: 30);

/// Maximum exponent for exponential backoff (2^5 = 32 seconds).
const int _maxBackoffExponent = 5;

/// Channel name shared with the Kotlin EngineBridge on Android.
const String _engineChannelName = 'com.bluessh/engine';

/// Manages all remote sessions through the native engine bridge.
///
/// On Android, communication goes through [MethodChannel] to the
/// Kotlin EngineBridge, which delegates to the Rust engine via JNI.
/// On desktop platforms, the [EngineBridge] (engine_bridge.dart) uses
/// dart:ffi directly.
class SessionService {
  static const _channel = MethodChannel(_engineChannelName);

  // ── Event streams ──────────────────────────────────────────────
  final _eventController = StreamController<SessionEvent>.broadcast();
  final _terminalDataController = StreamController<TerminalDataEvent>.broadcast();
  final _sftpController = StreamController<SftpEvent>.broadcast();
  final _clipboardController = StreamController<ClipboardEvent>.broadcast();
  final _authController = StreamController<AuthEvent>.broadcast();

  // ── Timer management ───────────────────────────────────────────
  final _keepaliveTimers = <int, Timer>{};
  final _reconnectTimers = <int, Timer>{};

  bool _initialized = false;

  /// Count of currently active sessions — drives foreground service.
  int _activeSessionCount = 0;

  // ── Public streams ─────────────────────────────────────────────

  /// Broadcast stream of session lifecycle events.
  Stream<SessionEvent> get events => _eventController.stream;

  /// Broadcast stream of raw terminal output data.
  Stream<TerminalDataEvent> get terminalData => _terminalDataController.stream;

  /// Broadcast stream of SFTP transfer progress events.
  Stream<SftpEvent> get sftpEvents => _sftpController.stream;

  /// Broadcast stream of remote clipboard update events.
  Stream<ClipboardEvent> get clipboardEvents => _clipboardController.stream;

  /// Broadcast stream of authentication challenge events.
  Stream<AuthEvent> get authEvents => _authController.stream;

  // ── Initialization ─────────────────────────────────────────────

  /// Initializes the native engine and registers the callback handler.
  /// Safe to call multiple times; subsequent calls are no-ops.
  Future<void> init() async {
    if (_initialized) return;
    try {
      await _channel.invokeMethod('init');
      _initialized = true;
      _registerCallbacks();
    } catch (e) {
      debugPrint('[SessionService] Engine init failed: $e');
    }
  }

  void _registerCallbacks() {
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onSessionStateChanged':
          final sessionId = call.arguments['sessionId'] as int;
          final state = call.arguments['state'] as String;
          _eventController.add(SessionEvent(
            sessionId: sessionId,
            type: state,
            data: call.arguments,
          ));
          break;
        case 'onTerminalData':
          final sessionId = call.arguments['sessionId'] as int;
          final data = call.arguments['data'] as Uint8List;
          _terminalDataController.add(TerminalDataEvent(
            sessionId: sessionId,
            data: data,
          ));
          break;
        case 'onSftpProgress':
          _sftpController.add(SftpEvent.fromJson(call.arguments));
          break;
        case 'onClipboardUpdate':
          final sessionId = call.arguments['sessionId'] as int;
          final data = call.arguments['data'] as Uint8List;
          _clipboardController.add(ClipboardEvent(
            sessionId: sessionId,
            data: data,
          ));
          break;
        case 'onAuthChallenge':
          final sessionId = call.arguments['sessionId'] as int;
          final methods = (call.arguments['methods'] as List).cast<String>();
          _authController.add(AuthEvent(
            sessionId: sessionId,
            methods: methods,
          ));
          break;
      }
    });
  }

  // ── Connection lifecycle ───────────────────────────────────────

  /// Establishes a connection to the remote host defined by [profile].
  ///
  /// Returns a positive [SessionId] on success, or `0` on failure.
  /// Automatically starts a keep-alive timer on success.
  Future<int> connect(HostProfile profile) async {
    await init();
    try {
      final sessionId = await _channel.invokeMethod<int>('connect', {
        'host': profile.host,
        'port': profile.port,
        'protocol': protocolToEngineValue(profile.protocol),
        'compressLevel': profile.compressionLevel,
        'recordSession': profile.recordSession,
        'username': profile.username,
      }).timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[SessionService] Connect timed out after 30s');
          return 0;
        },
      );

      if (sessionId != null && sessionId > 0) {
        _startKeepalive(sessionId);
        _activeSessionCount++;
        _updateForegroundService();
        return sessionId;
      }
      return 0;
    } on PlatformException catch (e) {
      debugPrint('[SessionService] Connect platform error: ${e.code} — ${e.message}');
      return 0;
    } catch (e) {
      debugPrint('[SessionService] Connect failed: $e');
      return 0;
    }
  }

  /// Authenticates a session using the credentials in [profile].
  ///
  /// Priority order: keyData > keyPath > password.
  /// Returns `0` on success, `-1` on failure.
  Future<int> authenticate(int sessionId, HostProfile profile) async {
    try {
      if (profile.keyData != null && profile.keyData!.isNotEmpty) {
        final keyBytes = base64Decode(profile.keyData!);
        return await _channel.invokeMethod<int>('authKeyData', {
              'sessionId': sessionId,
              'keyData': keyBytes,
              'passphrase': profile.passphrase ?? '',
            }) ??
            -1;
      } else if (profile.keyPath != null && profile.keyPath!.isNotEmpty) {
        return await _channel.invokeMethod<int>('authKey', {
              'sessionId': sessionId,
              'keyPath': profile.keyPath,
            }) ??
            -1;
      } else if (profile.password != null && profile.password!.isNotEmpty) {
        return await _channel.invokeMethod<int>('authPassword', {
              'sessionId': sessionId,
              'password': profile.password,
            }) ??
            -1;
      }
      debugPrint('[SessionService] No authentication method available');
      return -1;
    } on PlatformException catch (e) {
      debugPrint('[SessionService] Auth platform error: ${e.code} — ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('[SessionService] Auth failed: $e');
      return -1;
    }
  }

  /// Submits a multi-factor authentication [code] (e.g. TOTP) for a session.
  Future<int> submitMfa(int sessionId, String code) async {
    try {
      return await _channel.invokeMethod<int>('authMfa', {
            'sessionId': sessionId,
            'code': code,
          }) ??
          -1;
    } catch (e) {
      debugPrint('[SessionService] MFA submission failed: $e');
      return -1;
    }
  }

  /// Disconnects the session and cancels all associated timers.
  Future<int> disconnect(int sessionId) async {
    _stopKeepalive(sessionId);
    _stopReconnect(sessionId);
    _activeSessionCount = (_activeSessionCount - 1).clamp(0, 9999);
    _updateForegroundService();
    try {
      return await _channel.invokeMethod<int>('disconnect', {
            'sessionId': sessionId,
          }) ??
          -1;
    } on PlatformException catch (e) {
      debugPrint('[SessionService] Disconnect platform error: ${e.code} — ${e.message}');
      return -1;
    } catch (e) {
      debugPrint('[SessionService] Disconnect failed: $e');
      return -1;
    }
  }

  // ── Terminal I/O ───────────────────────────────────────────────

  /// Sends raw [data] bytes to the session's protocol channel.
  Future<int> write(int sessionId, Uint8List data) async {
    try {
      return await _channel.invokeMethod<int>('write', {
            'sessionId': sessionId,
            'data': data,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Sends a UTF-8 encoded string to the session.
  Future<int> writeString(int sessionId, String text) async {
    return write(sessionId, Uint8List.fromList(utf8.encode(text)));
  }

  /// Resizes the terminal PTY to [cols] x [rows].
  Future<int> resize(int sessionId, int cols, int rows) async {
    try {
      return await _channel.invokeMethod<int>('resize', {
            'sessionId': sessionId,
            'cols': cols,
            'rows': rows,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  // ── SFTP operations ────────────────────────────────────────────

  /// Lists the contents of a remote directory.
  /// Returns an empty list on failure.
  Future<List<SftpFileEntry>> sftpList(int sessionId, String path) async {
    try {
      final result = await _channel.invokeMethod<String>('sftpList', {
        'sessionId': sessionId,
        'path': path,
      });
      if (result == null || result.isEmpty) return [];
      final List<dynamic> items = jsonDecode(result);
      return items
          .map((e) => SftpFileEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      debugPrint('[SessionService] SFTP list failed: $e');
      return [];
    }
  }

  /// Uploads a local file to the remote path.
  Future<int> sftpUpload(
      int sessionId, String localPath, String remotePath) async {
    try {
      return await _channel.invokeMethod<int>('sftpUpload', {
            'sessionId': sessionId,
            'localPath': localPath,
            'remotePath': remotePath,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Downloads a remote file to the local path.
  Future<int> sftpDownload(
      int sessionId, String remotePath, String localPath) async {
    try {
      return await _channel.invokeMethod<int>('sftpDownload', {
            'sessionId': sessionId,
            'remotePath': remotePath,
            'localPath': localPath,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Creates a remote directory (including parents if needed).
  Future<int> sftpMkdir(int sessionId, String path) async {
    try {
      return await _channel.invokeMethod<int>('sftpMkdir', {
            'sessionId': sessionId,
            'path': path,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Deletes a remote file or empty directory.
  Future<int> sftpDelete(int sessionId, String path) async {
    try {
      return await _channel.invokeMethod<int>('sftpDelete', {
            'sessionId': sessionId,
            'path': path,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Renames or moves a remote file.
  Future<int> sftpRename(
      int sessionId, String oldPath, String newPath) async {
    try {
      return await _channel.invokeMethod<int>('sftpRename', {
            'sessionId': sessionId,
            'oldPath': oldPath,
            'newPath': newPath,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  // ── Clipboard ──────────────────────────────────────────────────

  /// Pushes local clipboard [data] to the remote session.
  Future<int> clipboardSet(int sessionId, Uint8List data) async {
    try {
      return await _channel.invokeMethod<int>('clipboardSet', {
            'sessionId': sessionId,
            'data': data,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Retrieves the remote session's clipboard content.
  Future<Uint8List?> clipboardGet() async {
    try {
      return await _channel.invokeMethod<Uint8List>('clipboardGet');
    } catch (e) {
      return null;
    }
  }

  // ── Recording ──────────────────────────────────────────────────

  /// Starts recording session output to the file at [path].
  Future<int> startRecording(int sessionId, String path) async {
    try {
      return await _channel.invokeMethod<int>('recordingStart', {
            'sessionId': sessionId,
            'path': path,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  /// Stops recording for the given session.
  Future<int> stopRecording(int sessionId) async {
    try {
      return await _channel.invokeMethod<int>('recordingStop', {
            'sessionId': sessionId,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  // ── Compression ────────────────────────────────────────────────

  /// Adjusts the adaptive compression [level] (0–3) for a session.
  Future<int> setCompression(int sessionId, int level) async {
    try {
      return await _channel.invokeMethod<int>('setCompression', {
            'sessionId': sessionId,
            'level': level,
          }) ??
          -1;
    } catch (e) {
      return -1;
    }
  }

  // ── App directory ──────────────────────────────────────────────

  /// Returns the application's writable documents directory path.
  Future<String> getAppDir() async {
    try {
      return await _channel.invokeMethod<String>('getAppDir') ?? '';
    } catch (e) {
      return '';
    }
  }

  // ── Keep-alive ─────────────────────────────────────────────────

  void _startKeepalive(int sessionId) {
    _stopKeepalive(sessionId);

    // Read interval from user settings
    SharedPreferences.getInstance().then((prefs) {
      final seconds = prefs.getInt('keepalive_interval') ?? 30;
      _keepaliveInterval = Duration(seconds: seconds);
      _keepaliveTimers[sessionId] = Timer.periodic(
        _keepaliveInterval,
        (_) => _sendKeepalive(sessionId),
      );
    });
  }

  void _stopKeepalive(int sessionId) {
    _keepaliveTimers[sessionId]?.cancel();
    _keepaliveTimers.remove(sessionId);
  }

  Future<void> _sendKeepalive(int sessionId) async {
    try {
      await _channel.invokeMethod<int>('write', {
        'sessionId': sessionId,
        'data': Uint8List.fromList([0]),
      });
    } catch (e) {
      _eventController.add(SessionEvent(
        sessionId: sessionId,
        type: 'keepalive_failed',
        data: {},
      ));
    }
  }

  // ── Session recovery ───────────────────────────────────────────

  /// Schedules automatic reconnection with exponential backoff.
  ///
  /// [maxAttempts] limits the total number of reconnection tries.
  /// Backoff delays double each attempt: 1s, 2s, 4s, 8s, 16s, 32s.
  void scheduleReconnect(
      int sessionId, HostProfile profile, int maxAttempts) {
    _stopReconnect(sessionId);
    int attempts = 0;

    void scheduleNext() {
      if (attempts >= maxAttempts) {
        _reconnectTimers.remove(sessionId);
        _eventController.add(SessionEvent(
          sessionId: sessionId,
          type: 'reconnect_failed',
          data: {'attempts': attempts},
        ));
        return;
      }

      attempts++;
      final backoffSeconds = 1 << (attempts - 1).clamp(0, _maxBackoffExponent);
      debugPrint(
        '[SessionService] Reconnect attempt $attempts for session '
        '$sessionId in ${backoffSeconds}s',
      );

      _reconnectTimers[sessionId] = Timer(
        Duration(seconds: backoffSeconds),
        () async {
          try {
            final newSessionId = await connect(profile);
            if (newSessionId > 0) {
              final authResult = await authenticate(newSessionId, profile);
              if (authResult == 0) {
                _reconnectTimers.remove(sessionId);
                _eventController.add(SessionEvent(
                  sessionId: newSessionId,
                  type: 'reconnected',
                  data: {
                    'oldSessionId': sessionId,
                    'attempts': attempts,
                  },
                ));
              } else {
                // Auth failed — clean up the new session and retry
                await disconnect(newSessionId);
                scheduleNext();
              }
            } else {
              // Connect failed — retry
              scheduleNext();
            }
          } catch (e) {
            debugPrint(
                '[SessionService] Reconnect attempt $attempts failed: $e');
            scheduleNext();
          }
        },
      );
    }

    scheduleNext();
  }

  void _stopReconnect(int sessionId) {
    _reconnectTimers[sessionId]?.cancel();
    _reconnectTimers.remove(sessionId);
  }

  // ── Android Foreground Service ─────────────────────────────────

  /// Starts or stops the Android foreground service based on active sessions.
  ///
  /// When at least one session is active, the service shows a persistent
  /// notification and tells the OS not to kill the process.  When all
  /// sessions disconnect, the service is stopped.
  ///
  /// On Android 13+ the notification permission must be granted or the
  /// foreground service cannot post its notification, which leads to a
  /// ForegroundServiceDidNotStartInTimeException crash.
  Future<void> _updateForegroundService() async {
    try {
      if (_activeSessionCount > 0) {
        // Verify notification permission before starting the foreground service
        if (Platform.isAndroid) {
          final status = await Permission.notification.status;
          if (!status.isGranted && !status.isLimited) {
            debugPrint(
              '[SessionService] Skipping foreground service — '
              'notification permission not granted',
            );
            return;
          }
        }
        await _channel.invokeMethod('startForeground');
      } else {
        await _channel.invokeMethod('stopForeground');
      }
    } catch (e) {
      // Silently ignore on non-Android platforms (desktop uses no service).
      debugPrint('[SessionService] Foreground service toggle: $e');
    }
  }

  /// Cancels all timers, stops the foreground service, and closes streams.
  void dispose() {
    for (final timer in _keepaliveTimers.values) {
      timer.cancel();
    }
    _keepaliveTimers.clear();
    for (final timer in _reconnectTimers.values) {
      timer.cancel();
    }
    _reconnectTimers.clear();
    _activeSessionCount = 0;
    _updateForegroundService();
    _eventController.close();
    _terminalDataController.close();
    _sftpController.close();
    _clipboardController.close();
    _authController.close();
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Event Types
// ═══════════════════════════════════════════════════════════════════

/// A generic session lifecycle event dispatched from the engine.
class SessionEvent {
  final int sessionId;
  final String type;
  final Map<String, dynamic> data;

  const SessionEvent({
    required this.sessionId,
    required this.type,
    required this.data,
  });
}

/// Raw terminal output data received from the remote session.
class TerminalDataEvent {
  final int sessionId;
  final Uint8List data;

  const TerminalDataEvent({
    required this.sessionId,
    required this.data,
  });
}

/// SFTP transfer progress event dispatched during file upload/download.
class SftpEvent {
  final int sessionId;
  final String type;
  final int fileId;
  final int bytesTransferred;
  final int totalBytes;
  final int speedBps;

  const SftpEvent({
    required this.sessionId,
    required this.type,
    this.fileId = 0,
    this.bytesTransferred = 0,
    this.totalBytes = 0,
    this.speedBps = 0,
  });

  factory SftpEvent.fromJson(dynamic json) {
    final map = json as Map;
    return SftpEvent(
      sessionId: map['sessionId'] as int,
      type: map['type'] as String,
      fileId: map['fileId'] as int? ?? 0,
      bytesTransferred: map['bytesTransferred'] as int? ?? 0,
      totalBytes: map['totalBytes'] as int? ?? 0,
      speedBps: map['speedBps'] as int? ?? 0,
    );
  }
}

/// Clipboard content received from the remote session.
class ClipboardEvent {
  final int sessionId;
  final Uint8List data;

  const ClipboardEvent({
    required this.sessionId,
    required this.data,
  });
}

/// Authentication challenge requiring user input (e.g. MFA codes).
class AuthEvent {
  final int sessionId;
  final List<String> methods;

  const AuthEvent({
    required this.sessionId,
    required this.methods,
  });
}

// ═══════════════════════════════════════════════════════════════════
//  Riverpod State Notifiers
// ═══════════════════════════════════════════════════════════════════

/// Manages the map of active session states for Riverpod consumers.
class ActiveSessionsNotifier extends StateNotifier<Map<int, SessionState>> {
  ActiveSessionsNotifier() : super({});

  void updateSession(int id, SessionState sessionState) {
    state = {...state, id: sessionState};
  }

  void removeSession(int id) {
    final newState = Map<int, SessionState>.from(state);
    newState.remove(id);
    state = newState;
  }

  void clear() {
    state = {};
  }
}

/// Manages the map of file transfer progress for Riverpod consumers.
class TransferProgressNotifier
    extends StateNotifier<Map<String, TransferProgress>> {
  TransferProgressNotifier() : super({});

  void updateTransfer(String id, TransferProgress progress) {
    state = {...state, id: progress};
  }

  void removeTransfer(String id) {
    final newState = Map<String, TransferProgress>.from(state);
    newState.remove(id);
    state = newState;
  }

  void clear() {
    state = {};
  }
}
