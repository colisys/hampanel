/// Aggregated security status returned by `/api/v1/security/overview`.
class SecurityOverview {
  const SecurityOverview({
    required this.firewall,
    required this.ssh,
    required this.waf,
    required this.fail2ban,
  });

  final SecurityFirewallSummary? firewall;
  final SecuritySshSummary? ssh;
  final SecurityWafSummary? waf;
  final SecurityFail2banSummary? fail2ban;

  factory SecurityOverview.fromJson(Map<String, dynamic> json) =>
      SecurityOverview(
        firewall: _map(json['firewall'], SecurityFirewallSummary.fromJson),
        ssh: _map(json['ssh'], SecuritySshSummary.fromJson),
        waf: _map(json['waf'], SecurityWafSummary.fromJson),
        fail2ban: _map(json['fail2ban'], SecurityFail2banSummary.fromJson),
      );
}

class SecurityFirewallSummary {
  const SecurityFirewallSummary({
    required this.available,
    required this.active,
    required this.rules,
  });

  final bool available;
  final bool active;
  final int rules;

  factory SecurityFirewallSummary.fromJson(Map<String, dynamic> json) =>
      SecurityFirewallSummary(
        available: json['available'] as bool? ?? false,
        active: json['active'] as bool? ?? false,
        rules: (json['rules'] as num?)?.toInt() ?? 0,
      );
}

class SecuritySshSummary {
  const SecuritySshSummary({
    required this.available,
    required this.running,
  });

  final bool available;
  final bool running;

  factory SecuritySshSummary.fromJson(Map<String, dynamic> json) =>
      SecuritySshSummary(
        available: json['available'] as bool? ?? false,
        running: json['running'] as bool? ?? false,
      );
}

class SecurityWafSummary {
  const SecurityWafSummary({
    required this.installed,
    required this.running,
    required this.mode,
  });

  final bool installed;
  final bool running;
  final String mode;

  factory SecurityWafSummary.fromJson(Map<String, dynamic> json) =>
      SecurityWafSummary(
        installed: json['installed'] as bool? ?? false,
        running: json['running'] as bool? ?? false,
        mode: json['mode'] as String? ?? '',
      );
}

class SecurityFail2banSummary {
  const SecurityFail2banSummary({
    required this.installed,
    required this.initialized,
    required this.active,
    required this.jails,
    required this.banned,
  });

  final bool installed;
  final bool initialized;
  final bool active;
  final int jails;
  final int banned;

  factory SecurityFail2banSummary.fromJson(Map<String, dynamic> json) =>
      SecurityFail2banSummary(
        installed: json['installed'] as bool? ?? false,
        initialized: json['initialized'] as bool? ?? false,
        active: json['active'] as bool? ?? false,
        jails: (json['jails'] as num?)?.toInt() ?? 0,
        banned: (json['banned'] as num?)?.toInt() ?? 0,
      );
}

/// Host capability probe. Anything false here means the panel must show why the
/// related feature cannot run, rather than an empty list.
class SecurityCapabilities {
  const SecurityCapabilities({
    required this.ebpf,
    required this.chattr,
    required this.qemu,
    required this.nft,
    required this.ufw,
    required this.selinux,
    required this.root,
  });

  final bool ebpf;
  final bool chattr;
  final bool qemu;
  final bool nft;
  final bool ufw;
  final bool selinux;
  final bool root;

  factory SecurityCapabilities.fromJson(Map<String, dynamic> json) =>
      SecurityCapabilities(
        ebpf: json['ebpf'] as bool? ?? false,
        chattr: json['chattr'] as bool? ?? false,
        qemu: json['qemu'] as bool? ?? false,
        nft: json['nft'] as bool? ?? false,
        ufw: json['ufw'] as bool? ?? false,
        selinux: json['selinux'] as bool? ?? false,
        root: json['root'] as bool? ?? false,
      );
}

T? _map<T>(
  Object? value,
  T Function(Map<String, dynamic> json) build,
) {
  if (value is! Map<String, dynamic>) return null;
  return build(value);
}
