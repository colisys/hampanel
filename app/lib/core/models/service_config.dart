class ServiceConfigFile {
  const ServiceConfigFile({
    required this.path,
    required this.content,
    required this.editable,
    required this.source,
  });

  final String path;
  final String content;
  final bool editable;
  final String source;

  factory ServiceConfigFile.fromJson(Map<String, dynamic> json) =>
      ServiceConfigFile(
        path: json['path'] as String? ?? '',
        content: json['content'] as String? ?? '',
        editable: json['editable'] as bool? ?? false,
        source: json['source'] as String? ?? 'vendor',
      );
}

class ServiceConfig {
  const ServiceConfig({
    required this.unit,
    required this.files,
    required this.dropinPath,
    required this.daemonReloadRequired,
  });

  final String unit;
  final List<ServiceConfigFile> files;
  final String dropinPath;
  final bool daemonReloadRequired;

  factory ServiceConfig.fromJson(Map<String, dynamic> json) => ServiceConfig(
    unit: json['unit'] as String? ?? '',
    files: ((json['files'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ServiceConfigFile.fromJson)
        .toList(),
    dropinPath: json['dropin_path'] as String? ?? '',
    daemonReloadRequired: json['daemon_reload_required'] as bool? ?? true,
  );
}
