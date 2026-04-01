/// Session recording service.
///
/// Records terminal (asciinema v2 format) and desktop (binary) sessions
/// to local files for later playback and audit.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import '../models/session_state.dart';

/// Manages recording of active remote sessions to disk.
///
/// Terminal sessions are recorded in asciinema v2 JSON format.
/// VNC/RDP sessions use a custom binary format with timestamped frames.
class RecordingService {
  static RecordingService? _instance;
  final _activeRecordings = <int, RecordingSession>{};

  RecordingService._();

  /// Returns the singleton instance.
  factory RecordingService.instance() =>
      _instance ??= RecordingService._();

  /// Returns the path to the recordings directory, creating it if needed.
  Future<String> get recordingsDir async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/recordings');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir.path;
  }

  /// Starts recording the given session.
  ///
  /// [sessionId] identifies the session.
  /// [protocol] is one of "ssh", "vnc", or "rdp".
  /// [customPath] overrides the default file location if provided.
  Future<RecordingSession> startRecording({
    required int sessionId,
    required String protocol,
    String? customPath,
  }) async {
    final dir = customPath ?? await recordingsDir;
    final timestamp = DateTime.now().millisecondsSinceEpoch;

    // Determine file extension based on protocol.
    final ext = protocol == 'vnc'
        ? 'vnc-rec'
        : protocol == 'rdp'
            ? 'rdp-rec'
            : 'cast';

    final path = '$dir/session_${sessionId}_$timestamp.$ext';

    final file = File(path);
    final sink = file.openWrite(mode: FileMode.append);

    // Write asciinema v2 header for terminal recordings.
    if (protocol == 'ssh') {
      final header = jsonEncode({
        'version': 2,
        'width': 80,
        'height': 24,
        'timestamp': timestamp ~/ 1000,
        'env': {'SHELL': '/bin/bash', 'TERM': 'xterm-256color'},
      });
      sink.writeln(header);
    }

    final session = RecordingSession(
      sessionId: sessionId,
      filePath: path,
      protocol: protocol,
      startTime: DateTime.now(),
      sink: sink,
    );

    _activeRecordings[sessionId] = session;
    return session;
  }

  /// Writes a data frame to the active recording for [sessionId].
  ///
  /// For SSH sessions, frames are serialized as asciinema JSON lines.
  /// For VNC/RDP sessions, frames use a binary format:
  ///   [timestamp_ms: u32 LE][frame_length: u32 LE][frame_data: bytes]
  Future<void> writeFrame(int sessionId, List<int> data) async {
    final session = _activeRecordings[sessionId];
    if (session == null) return;

    final elapsed = DateTime.now().difference(session.startTime);

    if (session.protocol == 'ssh') {
      final frame = jsonEncode([
        elapsed.inMilliseconds / 1000.0,
        'o',
        utf8.decode(data, allowMalformed: true),
      ]);
      session.sink.writeln(frame);
    } else {
      final timestampBytes = ByteData(4)
        ..setUint32(0, elapsed.inMilliseconds, Endian.little);
      final lengthBytes = ByteData(4)
        ..setUint32(0, data.length, Endian.little);
      session.sink.add(timestampBytes.buffer.asUint8List());
      session.sink.add(lengthBytes.buffer.asUint8List());
      session.sink.add(data);
    }

    session.bytesWritten += data.length;
  }

  /// Stops recording for [sessionId] and returns metadata about the file.
  /// Returns `null` if no recording was active for that session.
  Future<RecordingInfo?> stopRecording(int sessionId) async {
    final session = _activeRecordings.remove(sessionId);
    if (session == null) return null;

    await session.sink.flush();
    await session.sink.close();

    final file = File(session.filePath);
    final size = await file.exists() ? await file.length() : 0;

    return RecordingInfo(
      id: sessionId.toString(),
      sessionId: sessionId.toString(),
      path: session.filePath,
      startTime: session.startTime,
      endTime: DateTime.now(),
      sizeBytes: size,
      protocol: session.protocol,
    );
  }

  /// Lists all recording files on disk, sorted newest-first.
  Future<List<RecordingInfo>> listRecordings() async {
    final dir = await recordingsDir;
    final directory = Directory(dir);
    if (!await directory.exists()) return [];

    final files = await directory.list().toList();
    final recordings = <RecordingInfo>[];

    for (final file in files) {
      if (file is File) {
        final stat = await file.stat();
        final name = file.uri.pathSegments.last;
        final protocol = name.endsWith('.cast')
            ? 'ssh'
            : name.endsWith('.vnc-rec')
                ? 'vnc'
                : 'rdp';
        recordings.add(RecordingInfo(
          id: name,
          sessionId: '',
          path: file.path,
          startTime: stat.modified,
          sizeBytes: stat.size,
          protocol: protocol,
        ));
      }
    }

    recordings.sort((a, b) => b.startTime.compareTo(a.startTime));
    return recordings;
  }

  /// Deletes a recording file at the given [path].
  Future<void> deleteRecording(String path) async {
    final file = File(path);
    if (await file.exists()) {
      await file.delete();
    }
  }

  /// Flushes and closes all active recordings.
  void dispose() {
    for (final session in _activeRecordings.values) {
      try {
        session.sink.close();
      } catch (_) {
        // Sink may already be closed — ignore
      }
    }
    _activeRecordings.clear();
  }
}

/// An active recording session with its output sink.
class RecordingSession {
  final int sessionId;
  final String filePath;
  final String protocol;
  final DateTime startTime;
  final IOSink sink;
  int bytesWritten = 0;

  RecordingSession({
    required this.sessionId,
    required this.filePath,
    required this.protocol,
    required this.startTime,
    required this.sink,
  });

  /// Elapsed time since recording started.
  Duration get duration => DateTime.now().difference(startTime);
}
