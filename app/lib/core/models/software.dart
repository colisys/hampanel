class SoftwareItem {
  const SoftwareItem({
    required this.id,
    required this.name,
    required this.description,
    required this.installed,
    required this.initialized,
    required this.needsInitialization,
    required this.active,
    required this.version,
    required this.service,
    required this.manageHint,
  });

  final String id;
  final String name;
  final String description;
  final bool installed;
  final bool initialized;
  final bool needsInitialization;
  final bool active;
  final String version;
  final String service;
  final String manageHint;

  factory SoftwareItem.fromJson(Map<String, dynamic> json) => SoftwareItem(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        description: json['description'] as String? ?? '',
        installed: json['installed'] as bool? ?? false,
        initialized: json['initialized'] as bool? ?? false,
        needsInitialization: json['needs_initialization'] as bool? ?? false,
        active: json['active'] as bool? ?? false,
        version: json['version'] as String? ?? '',
        service: json['service'] as String? ?? '',
        manageHint: json['manage_hint'] as String? ?? '',
      );
}
