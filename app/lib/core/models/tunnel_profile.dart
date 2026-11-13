class TunnelProfile {
  TunnelProfile({
    required this.id,
    required this.name,
    required this.mode,
    required this.sshHost,
    required this.sshPort,
    required this.sshUser,
    required this.keyPath,
    required this.localPort,
    required this.remotePort,
    required this.targetHost,
    required this.targetPort,
    required this.createdAt,
    this.jumpHost = '',
  });

  final String id;
  String name;

  /// local (-L), remote (-R), socks (-D), socat
  String mode;
  String sshHost;
  int sshPort;
  String sshUser;
  String keyPath;

  /// Optional single jump host for ssh -J, e.g. ops@bastion.example.com:2222
  String jumpHost;
  int localPort;
  int remotePort;
  String targetHost;
  int targetPort;
  final int createdAt;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'mode': mode,
    'ssh_host': sshHost,
    'ssh_port': sshPort,
    'ssh_user': sshUser,
    'key_path': keyPath,
    'jump_host': jumpHost,
    'local_port': localPort,
    'remote_port': remotePort,
    'target_host': targetHost,
    'target_port': targetPort,
    'created_at': createdAt,
  };

  factory TunnelProfile.fromJson(Map<String, dynamic> json) => TunnelProfile(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    mode: json['mode'] as String? ?? 'local',
    sshHost: json['ssh_host'] as String? ?? '',
    sshPort: (json['ssh_port'] as num?)?.toInt() ?? 22,
    sshUser: json['ssh_user'] as String? ?? '',
    keyPath: json['key_path'] as String? ?? '',
    jumpHost: json['jump_host'] as String? ?? '',
    localPort: (json['local_port'] as num?)?.toInt() ?? 0,
    remotePort: (json['remote_port'] as num?)?.toInt() ?? 0,
    targetHost: json['target_host'] as String? ?? '',
    targetPort: (json['target_port'] as num?)?.toInt() ?? 0,
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
  );
}
