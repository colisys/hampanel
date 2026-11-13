class NixTarget {
  const NixTarget({
    required this.id,
    required this.name,
    required this.description,
  });

  final String id;
  final String name;
  final String description;

  factory NixTarget.fromJson(Map<String, dynamic> json) => NixTarget(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
  );
}

class NixStatus {
  const NixStatus({
    required this.available,
    required this.version,
    required this.flakes,
    required this.targets,
  });

  final bool available;
  final String version;
  final bool flakes;
  final List<NixTarget> targets;

  factory NixStatus.fromJson(Map<String, dynamic> json) => NixStatus(
    available: json['available'] as bool? ?? false,
    version: json['version'] as String? ?? '',
    flakes: json['flakes'] as bool? ?? false,
    targets: ((json['targets'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(NixTarget.fromJson)
        .toList(),
  );
}
