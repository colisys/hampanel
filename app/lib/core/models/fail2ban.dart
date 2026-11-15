class Fail2banJail {
  const Fail2banJail({
    required this.name,
    required this.currentlyFailed,
    required this.totalFailed,
    required this.currentlyBanned,
    required this.totalBanned,
    required this.maxretry,
    required this.bantime,
    required this.findtime,
    required this.bannedIps,
  });

  final String name;
  final int currentlyFailed;
  final int totalFailed;
  final int currentlyBanned;
  final int totalBanned;
  final String maxretry;
  final String bantime;
  final String findtime;
  final List<String> bannedIps;

  factory Fail2banJail.fromJson(Map<String, dynamic> json) => Fail2banJail(
    name: json['name'] as String? ?? '',
    currentlyFailed: (json['currently_failed'] as num?)?.toInt() ?? 0,
    totalFailed: (json['total_failed'] as num?)?.toInt() ?? 0,
    currentlyBanned: (json['currently_banned'] as num?)?.toInt() ?? 0,
    totalBanned: (json['total_banned'] as num?)?.toInt() ?? 0,
    maxretry: json['maxretry'] as String? ?? '',
    bantime: json['bantime'] as String? ?? '',
    findtime: json['findtime'] as String? ?? '',
    bannedIps: ((json['banned_ips'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
  );
}

class Fail2banStatus {
  const Fail2banStatus({
    required this.installed,
    required this.initialized,
    required this.active,
    required this.version,
    required this.jails,
    required this.message,
  });

  final bool installed;
  final bool initialized;
  final bool active;
  final String version;
  final List<Fail2banJail> jails;
  final String message;

  factory Fail2banStatus.fromJson(Map<String, dynamic> json) => Fail2banStatus(
    installed: json['installed'] as bool? ?? false,
    initialized: json['initialized'] as bool? ?? false,
    active: json['active'] as bool? ?? false,
    version: json['version'] as String? ?? '',
    jails: ((json['jails'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Fail2banJail.fromJson)
        .toList(),
    message: json['message'] as String? ?? '',
  );
}
