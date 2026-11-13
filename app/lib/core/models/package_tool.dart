class PackageTool {
  const PackageTool({
    required this.id,
    required this.name,
    required this.description,
    required this.binary,
    required this.installed,
  });

  final String id;
  final String name;
  final String description;
  final String binary;
  final bool installed;

  factory PackageTool.fromJson(Map<String, dynamic> json) => PackageTool(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    binary: json['binary'] as String? ?? '',
    installed: json['installed'] as bool? ?? false,
  );
}

class PackageStatus {
  const PackageStatus({
    required this.manager,
    required this.available,
    required this.tools,
  });

  final String manager;
  final bool available;
  final List<PackageTool> tools;

  factory PackageStatus.fromJson(Map<String, dynamic> json) => PackageStatus(
    manager: json['manager'] as String? ?? 'none',
    available: json['available'] as bool? ?? false,
    tools: ((json['tools'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(PackageTool.fromJson)
        .toList(),
  );
}
