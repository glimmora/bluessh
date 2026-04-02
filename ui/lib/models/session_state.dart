/// Session state and transfer progress models.
///
/// Defines the data structures used to track the lifecycle of remote
/// sessions and monitor file transfer progress.
library;

/// High-level connection status of a remote session.
enum SessionStatus {
  /// No active connection.
  disconnected,

  /// TCP connection being established.
  connecting,

  /// SSH handshake or credential exchange in progress.
  authenticating,

  /// Fully connected and operational.
  connected,

  /// Attempting automatic reconnection after a drop.
  reconnecting,

  /// Unrecoverable error state.
  error;

  /// Whether the session is in a transitively active state
  /// (i.e. likely to become connected soon).
  bool get isActive =>
      this == connecting ||
      this == authenticating ||
      this == connected ||
      this == reconnecting;
}

/// Immutable snapshot of a session's current state.
class SessionState {
  final int sessionId;
  final SessionStatus status;
  final String? errorMessage;
  final int reconnectAttempts;
  final DateTime? connectedAt;
  final Duration? latency;
  final int bytesSent;
  final int bytesReceived;

  const SessionState({
    required this.sessionId,
    required this.status,
    this.errorMessage,
    this.reconnectAttempts = 0,
    this.connectedAt,
    this.latency,
    this.bytesSent = 0,
    this.bytesReceived = 0,
  });

  /// Returns a copy with the specified fields replaced.
  SessionState copyWith({
    int? sessionId,
    SessionStatus? status,
    String? errorMessage,
    int? reconnectAttempts,
    DateTime? connectedAt,
    Duration? latency,
    int? bytesSent,
    int? bytesReceived,
  }) {
    return SessionState(
      sessionId: sessionId ?? this.sessionId,
      status: status ?? this.status,
      errorMessage: errorMessage ?? this.errorMessage,
      reconnectAttempts: reconnectAttempts ?? this.reconnectAttempts,
      connectedAt: connectedAt ?? this.connectedAt,
      latency: latency ?? this.latency,
      bytesSent: bytesSent ?? this.bytesSent,
      bytesReceived: bytesReceived ?? this.bytesReceived,
    );
  }
}

/// Tracks the progress of an individual SFTP file transfer.
class TransferProgress {
  final String id;
  final String fileName;
  final String remotePath;
  final String localPath;
  final int totalBytes;
  final int transferredBytes;
  final int speedBps;
  final bool isUpload;
  final bool isComplete;
  final String? error;

  const TransferProgress({
    required this.id,
    required this.fileName,
    required this.remotePath,
    required this.localPath,
    required this.totalBytes,
    required this.transferredBytes,
    required this.speedBps,
    required this.isUpload,
    this.isComplete = false,
    this.error,
  });

  /// Transfer completion ratio, clamped to [0.0, 1.0].
  double get progress =>
      totalBytes > 0 ? (transferredBytes / totalBytes).clamp(0.0, 1.0) : 0.0;

  /// Human-readable throughput string (e.g. "1.2 MB/s").
  String get speedText {
    if (speedBps < 1024) return '$speedBps B/s';
    if (speedBps < 1024 * 1024) return '${(speedBps / 1024).toStringAsFixed(1)} KB/s';
    return '${(speedBps / (1024 * 1024)).toStringAsFixed(1)} MB/s';
  }

  /// Human-readable progress string (e.g. "3.4 MB / 10.0 MB").
  String get sizeText {
    if (transferredBytes < 1024) return '$transferredBytes B';
    if (transferredBytes < 1024 * 1024) {
      return '${(transferredBytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(transferredBytes / (1024 * 1024)).toStringAsFixed(1)} MB / '
        '${(totalBytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  /// Returns a copy with transfer-specific fields replaced.
  TransferProgress copyWith({
    int? transferredBytes,
    int? speedBps,
    bool? isComplete,
    String? error,
  }) {
    return TransferProgress(
      id: id,
      fileName: fileName,
      remotePath: remotePath,
      localPath: localPath,
      totalBytes: totalBytes,
      transferredBytes: transferredBytes ?? this.transferredBytes,
      speedBps: speedBps ?? this.speedBps,
      isUpload: isUpload,
      isComplete: isComplete ?? this.isComplete,
      error: error,
    );
  }
}

/// A single file or directory entry returned by an SFTP `readdir` operation.
class SftpFileEntry {
  final String name;
  final String path;
  final int size;
  final bool isDirectory;
  final DateTime? modifiedTime;
  final int permissions;
  final String owner;

  const SftpFileEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.isDirectory,
    this.modifiedTime,
    this.permissions = 0,
    this.owner = '',
  });

  /// Human-readable file size (e.g. "2.3 MB") or "<DIR>" for directories.
  String get sizeText {
    if (isDirectory) return '<DIR>';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }

  /// Unix-style permission string (e.g. "drwxr-xr--").
  String get permissionsText {
    final sb = StringBuffer();
    sb.write(isDirectory ? 'd' : '-');
    sb.write((permissions & 0x100) != 0 ? 'r' : '-');
    sb.write((permissions & 0x080) != 0 ? 'w' : '-');
    sb.write((permissions & 0x040) != 0 ? 'x' : '-');
    sb.write((permissions & 0x020) != 0 ? 'r' : '-');
    sb.write((permissions & 0x010) != 0 ? 'w' : '-');
    sb.write((permissions & 0x008) != 0 ? 'x' : '-');
    sb.write((permissions & 0x004) != 0 ? 'r' : '-');
    sb.write((permissions & 0x002) != 0 ? 'w' : '-');
    sb.write((permissions & 0x001) != 0 ? 'x' : '-');
    return sb.toString();
  }

  /// Deserializes from a JSON map returned by the SFTP bridge.
  factory SftpFileEntry.fromJson(Map<String, dynamic> json) {
    return SftpFileEntry(
      name: json['name'] as String,
      path: json['path'] as String,
      size: json['size'] as int? ?? 0,
      isDirectory: json['isDirectory'] as bool? ?? false,
      modifiedTime: json['modifiedTime'] != null
          ? DateTime.parse(json['modifiedTime'] as String)
          : null,
      permissions: json['permissions'] as int? ?? 0,
      owner: json['owner'] as String? ?? '',
    );
  }
}

/// Metadata about a completed or in-progress session recording.
class RecordingInfo {
  final String id;
  final String sessionId;
  final String path;
  final DateTime startTime;
  final DateTime? endTime;
  final int sizeBytes;
  final String protocol;

  const RecordingInfo({
    required this.id,
    required this.sessionId,
    required this.path,
    required this.startTime,
    this.endTime,
    this.sizeBytes = 0,
    required this.protocol,
  });

  /// Duration of the recording. If still recording, uses current time.
  Duration get duration =>
      (endTime ?? DateTime.now()).difference(startTime);

  /// Human-readable duration string (e.g. "1h 23m 45s").
  String get durationText {
    final d = duration;
    final hours = d.inHours;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (hours > 0) return '${hours}h ${minutes}m ${seconds}s';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }
}
