class SshStatus {
  const SshStatus({
    required this.available,
    required this.active,
    required this.service,
    required this.version,
    required this.port,
    required this.permitRootLogin,
    required this.passwordAuthentication,
    required this.pubkeyAuthentication,
    required this.dropIn,
    required this.currentUser,
    required this.message,
  });

  final bool available;
  final bool active;
  final String service;
  final String version;
  final String port;
  final String permitRootLogin;
  final String passwordAuthentication;
  final String pubkeyAuthentication;
  final String dropIn;
  final String currentUser;
  final String message;

  factory SshStatus.fromJson(Map<String, dynamic> json) => SshStatus(
        available: json['available'] as bool? ?? false,
        active: json['active'] as bool? ?? false,
        service: json['service'] as String? ?? '',
        version: json['version'] as String? ?? '',
        port: json['port'] as String? ?? '',
        permitRootLogin: json['permit_root_login'] as String? ?? '',
        passwordAuthentication: json['password_authentication'] as String? ?? '',
        pubkeyAuthentication: json['pubkey_authentication'] as String? ?? '',
        dropIn: json['drop_in'] as String? ?? '',
        currentUser: json['current_user'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );
}

class SshKey {
  const SshKey({
    required this.index,
    required this.keyType,
    required this.comment,
    required this.key,
  });

  final int index;
  final String keyType;
  final String comment;
  final String key;

  factory SshKey.fromJson(Map<String, dynamic> json) => SshKey(
        index: (json['index'] as num?)?.toInt() ?? 0,
        keyType: json['key_type'] as String? ?? '',
        comment: json['comment'] as String? ?? '',
        key: json['key'] as String? ?? '',
      );
}
