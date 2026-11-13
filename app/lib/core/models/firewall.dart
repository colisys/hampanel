class FirewallRule {
  const FirewallRule({
    required this.id,
    required this.to,
    required this.action,
    required this.from,
    required this.raw,
  });

  final String id;
  final String to;
  final String action;
  final String from;
  final String raw;

  factory FirewallRule.fromJson(Map<String, dynamic> json) => FirewallRule(
    id: json['id'] as String? ?? '',
    to: json['to'] as String? ?? '',
    action: json['action'] as String? ?? '',
    from: json['from'] as String? ?? '',
    raw: json['raw'] as String? ?? '',
  );
}

class FirewallStatus {
  const FirewallStatus({
    required this.available,
    required this.active,
    required this.rules,
    required this.output,
  });

  final bool available;
  final bool active;
  final List<FirewallRule> rules;
  final String output;

  factory FirewallStatus.fromJson(Map<String, dynamic> json) => FirewallStatus(
    available: json['available'] as bool? ?? false,
    active: json['active'] as bool? ?? false,
    rules: ((json['rules'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(FirewallRule.fromJson)
        .toList(),
    output: json['output'] as String? ?? '',
  );
}
