/// Port forwarding model for SSH tunneling support.
library;

/// Type of port forwarding.
enum ForwardType {
  local('Local', 'Remote \u2192 local port'),
  remote('Remote', 'Local \u2192 remote port'),
  dynamic('SOCKS5', 'Dynamic proxy');

  final String label;
  final String description;
  const ForwardType(this.label, this.description);
}

/// A single port forwarding rule.
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

  Map<String, dynamic> toJson() => {
        'id': id,
        'type': type.index,
        'localPort': localPort,
        'remoteHost': remoteHost,
        'remotePort': remotePort,
        'enabled': enabled,
      };

  factory PortForward.fromJson(Map<String, dynamic> json) {
    return PortForward(
      id: json['id'] as String,
      type: ForwardType.values[json['type'] as int],
      localPort: json['localPort'] as int,
      remoteHost: json['remoteHost'] as String,
      remotePort: json['remotePort'] as int,
      enabled: json['enabled'] as bool? ?? true,
    );
  }

  PortForward copyWith({bool? enabled}) {
    return PortForward(
      id: id,
      type: type,
      localPort: localPort,
      remoteHost: remoteHost,
      remotePort: remotePort,
      enabled: enabled ?? this.enabled,
    );
  }
}
