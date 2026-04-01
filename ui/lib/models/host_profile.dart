/// Host profile model — persisted connection configuration.
///
/// Stores all parameters needed to establish and maintain a remote
/// session, including authentication credentials, protocol settings,
/// and user preferences.
library;

import 'dart:convert';
import 'port_forward.dart';
export 'port_forward.dart';

/// Supported remote-access protocols with metadata.
enum ProtocolType {
  /// SSH-2 protocol for terminal/shell access.
  ssh(0, 'SSH', 'Terminal'),

  /// SFTP v3 file transfer over an SSH channel.
  sftp(1, 'SFTP', 'File Transfer'),

  /// RFB 3.8 (VNC) graphical remote desktop.
  vnc(2, 'VNC', 'Remote Desktop'),

  /// RDP 10.x Windows remote desktop.
  rdp(3, 'RDP', 'Remote Desktop');

  final int value;
  final String label;
  final String category;

  const ProtocolType(this.value, this.label, this.category);

  /// Safe lookup by integer value with fallback to ssh.
  static ProtocolType byValue(int v) {
    for (final p in ProtocolType.values) {
      if (p.value == v) return p;
    }
    return ProtocolType.ssh;
  }
}

/// Immutable connection profile for a single remote host.
///
/// Use the named constructors [HostProfile.ssh], [HostProfile.vnc],
/// and [HostProfile.rdp] for quick creation with protocol-appropriate
/// defaults.  Use [copyWith] for non-destructive updates.
class HostProfile {
  /// Unique identifier (microsecond timestamp string).
  final String id;

  /// User-facing display name (e.g. "Production Server").
  final String name;

  /// Hostname or IP address of the remote machine.
  final String host;

  /// TCP port (SSH=22, VNC=5900, RDP=3389).
  final int port;

  /// Protocol to use for this connection.
  final ProtocolType protocol;

  /// Remote username (empty for VNC-only connections).
  final String username;

  /// Plaintext password (stored encrypted at rest via CredentialService).
  final String? password;

  /// Filesystem path to an SSH private key.
  final String? keyPath;

  /// Base64-encoded private key data (for Android import).
  final String? keyData;

  /// Passphrase to decrypt an encrypted private key.
  final String? passphrase;

  /// Adaptive compression level (0=None, 1=Low, 2=Med, 3=High).
  final int compressionLevel;

  /// Whether to record this session to a file.
  final bool recordSession;

  /// Whether multi-factor authentication (TOTP) is enabled.
  final bool useMfa;

  /// Encrypted TOTP shared secret for MFA.
  final String? mfaSecret;

  /// Timestamp of the last successful connection.
  final DateTime lastUsed;

  /// Total number of successful connections to this host.
  final int connectionCount;

  /// Custom environment variables to set on the remote shell.
  final Map<String, String> envVars;

  /// Preferred working directory after login.
  final String? workingDirectory;

  /// User-defined tags for filtering and organization.
  final List<String> tags;

  // ── Jump Host Fields ────────────────────────────────────────────

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

  // ── Port Forwarding ─────────────────────────────────────────────

  /// Port forwarding rules for this connection.
  final List<PortForward> portForwards;

  // ── Agent Forwarding ────────────────────────────────────────────

  /// Whether to forward the SSH agent to the remote host.
  final bool agentForwarding;

  const HostProfile({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
    required this.username,
    this.password,
    this.keyPath,
    this.keyData,
    this.passphrase,
    this.compressionLevel = 2,
    this.recordSession = false,
    this.useMfa = false,
    this.mfaSecret,
    required this.lastUsed,
    this.connectionCount = 0,
    this.envVars = const {},
    this.workingDirectory,
    this.tags = const [],
    this.jumpHost,
    this.jumpPort = 22,
    this.jumpUsername,
    this.jumpPassword,
    this.jumpKeyPath,
    this.portForwards = const [],
    this.agentForwarding = false,
  });

  /// Creates an SSH host profile with sensible defaults (port 22, medium compression).
  factory HostProfile.ssh({
    required String name,
    required String host,
    required String username,
    int port = 22,
    String? password,
    String? keyPath,
    int compressionLevel = 2,
  }) {
    return HostProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      host: host,
      port: port,
      protocol: ProtocolType.ssh,
      username: username,
      password: password,
      keyPath: keyPath,
      lastUsed: DateTime.now(),
      compressionLevel: compressionLevel,
    );
  }

  /// Creates a VNC host profile (port 5900, no username required).
  factory HostProfile.vnc({
    required String name,
    required String host,
    int port = 5900,
    String? password,
  }) {
    return HostProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      host: host,
      port: port,
      protocol: ProtocolType.vnc,
      username: '',
      password: password,
      lastUsed: DateTime.now(),
    );
  }

  /// Creates an RDP host profile (port 3389).
  factory HostProfile.rdp({
    required String name,
    required String host,
    required String username,
    int port = 3389,
    String? password,
  }) {
    return HostProfile(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: name,
      host: host,
      port: port,
      protocol: ProtocolType.rdp,
      username: username,
      password: password,
      lastUsed: DateTime.now(),
    );
  }

  /// Returns a copy with the specified fields replaced.
  /// The [id] is always preserved from the original.
  HostProfile copyWith({
    String? name,
    String? host,
    int? port,
    ProtocolType? protocol,
    String? username,
    String? password,
    String? keyPath,
    String? keyData,
    String? passphrase,
    int? compressionLevel,
    bool? recordSession,
    bool? useMfa,
    String? mfaSecret,
    DateTime? lastUsed,
    int? connectionCount,
    Map<String, String>? envVars,
    String? workingDirectory,
    List<String>? tags,
    String? jumpHost,
    int? jumpPort,
    String? jumpUsername,
    String? jumpPassword,
    String? jumpKeyPath,
    List<PortForward>? portForwards,
    bool? agentForwarding,
  }) {
    return HostProfile(
      id: id,
      name: name ?? this.name,
      host: host ?? this.host,
      port: port ?? this.port,
      protocol: protocol ?? this.protocol,
      username: username ?? this.username,
      password: password ?? this.password,
      keyPath: keyPath ?? this.keyPath,
      keyData: keyData ?? this.keyData,
      passphrase: passphrase ?? this.passphrase,
      compressionLevel: compressionLevel ?? this.compressionLevel,
      recordSession: recordSession ?? this.recordSession,
      useMfa: useMfa ?? this.useMfa,
      mfaSecret: mfaSecret ?? this.mfaSecret,
      lastUsed: lastUsed ?? this.lastUsed,
      connectionCount: connectionCount ?? this.connectionCount,
      envVars: envVars ?? this.envVars,
      workingDirectory: workingDirectory ?? this.workingDirectory,
      tags: tags ?? this.tags,
      jumpHost: jumpHost ?? this.jumpHost,
      jumpPort: jumpPort ?? this.jumpPort,
      jumpUsername: jumpUsername ?? this.jumpUsername,
      jumpPassword: jumpPassword ?? this.jumpPassword,
      jumpKeyPath: jumpKeyPath ?? this.jumpKeyPath,
      portForwards: portForwards ?? this.portForwards,
      agentForwarding: agentForwarding ?? this.agentForwarding,
    );
  }

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
      'jumpHost': jumpHost,
      'jumpPort': jumpPort,
      'jumpUsername': jumpUsername,
      'jumpKeyPath': jumpKeyPath,
      'portForwards': portForwards.map((f) => f.toJson()).toList(),
      'agentForwarding': agentForwarding,
    };

    if (includeCredentials) {
      map['password'] = password;
      map['keyData'] = keyData;
      map['passphrase'] = passphrase;
      map['mfaSecret'] = mfaSecret;
      map['jumpPassword'] = jumpPassword;
    }

    return map;
  }

  /// Deserializes from a JSON map.
  factory HostProfile.fromJson(Map<String, dynamic> json) {
    return HostProfile(
      id: json['id'] as String,
      name: json['name'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      protocol: ProtocolType.byValue(json['protocol'] as int),
      username: json['username'] as String,
      password: json['password'] as String?,
      keyPath: json['keyPath'] as String?,
      keyData: json['keyData'] as String?,
      passphrase: json['passphrase'] as String?,
      mfaSecret: json['mfaSecret'] as String?,
      compressionLevel: json['compressionLevel'] as int? ?? 2,
      recordSession: json['recordSession'] as bool? ?? false,
      useMfa: json['useMfa'] as bool? ?? false,
      lastUsed: DateTime.parse(json['lastUsed'] as String),
      connectionCount: json['connectionCount'] as int? ?? 0,
      envVars: (json['envVars'] as Map?)?.cast<String, String>() ?? {},
      workingDirectory: json['workingDirectory'] as String?,
      tags: (json['tags'] as List?)?.cast<String>() ?? [],
      jumpHost: json['jumpHost'] as String?,
      jumpPort: json['jumpPort'] as int? ?? 22,
      jumpUsername: json['jumpUsername'] as String?,
      jumpPassword: json['jumpPassword'] as String?,
      jumpKeyPath: json['jumpKeyPath'] as String?,
      portForwards: (json['portForwards'] as List?)
              ?.map((f) => PortForward.fromJson(f as Map<String, dynamic>))
              .toList() ??
          [],
      agentForwarding: json['agentForwarding'] as bool? ?? false,
    );
  }

  /// Convenience: JSON string serialization.
  String toJsonString() => jsonEncode(toJson());

  /// Convenience: JSON string deserialization.
  factory HostProfile.fromJsonString(String source) =>
      HostProfile.fromJson(jsonDecode(source));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HostProfile && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
