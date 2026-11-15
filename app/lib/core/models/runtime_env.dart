class RuntimeExtension {
  const RuntimeExtension({required this.id, required this.label});

  final String id;
  final String label;

  factory RuntimeExtension.fromJson(Map<String, dynamic> json) =>
      RuntimeExtension(
        id: json['id'] as String? ?? '',
        label: json['label'] as String? ?? '',
      );
}

class RuntimeConfigSpec {
  const RuntimeConfigSpec({required this.name, required this.containerPath});

  final String name;
  final String containerPath;

  factory RuntimeConfigSpec.fromJson(Map<String, dynamic> json) =>
      RuntimeConfigSpec(
        name: json['name'] as String? ?? '',
        containerPath: json['container_path'] as String? ?? '',
      );
}

class RuntimePreset {
  const RuntimePreset({
    required this.id,
    required this.name,
    required this.description,
    required this.image,
    required this.tag,
    required this.workdir,
    required this.webPort,
    required this.recommendedTags,
    required this.extensions,
    required this.configFiles,
  });

  final String id;
  final String name;
  final String description;
  final String image;
  final String tag;
  final String workdir;
  final int webPort;
  final List<String> recommendedTags;
  final List<RuntimeExtension> extensions;
  final List<RuntimeConfigSpec> configFiles;

  factory RuntimePreset.fromJson(Map<String, dynamic> json) => RuntimePreset(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    image: json['image'] as String? ?? '',
    tag: json['tag'] as String? ?? '',
    workdir: json['workdir'] as String? ?? '/app',
    webPort: (json['web_port'] as num?)?.toInt() ?? 8080,
    recommendedTags: ((json['recommended_tags'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    extensions: ((json['extensions'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RuntimeExtension.fromJson)
        .toList(),
    configFiles: ((json['config_files'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RuntimeConfigSpec.fromJson)
        .toList(),
  );

  RuntimeExtension? extensionById(String id) {
    for (final extension in extensions) {
      if (extension.id == id) return extension;
    }
    return null;
  }
}

class RuntimeMirror {
  const RuntimeMirror({required this.id, required this.label});

  final String id;
  final String label;

  factory RuntimeMirror.fromJson(Map<String, dynamic> json) => RuntimeMirror(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
  );
}

class RuntimeCatalog {
  const RuntimeCatalog({required this.runtimes, required this.mirrors});

  final List<RuntimePreset> runtimes;
  final List<RuntimeMirror> mirrors;

  factory RuntimeCatalog.fromJson(Map<String, dynamic> json) => RuntimeCatalog(
    runtimes: ((json['runtimes'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RuntimePreset.fromJson)
        .toList(),
    mirrors: ((json['mirrors'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(RuntimeMirror.fromJson)
        .toList(),
  );

  RuntimePreset? presetById(String id) {
    for (final runtime in runtimes) {
      if (runtime.id == id) return runtime;
    }
    return null;
  }
}

class RuntimeEnvironment {
  const RuntimeEnvironment({
    required this.id,
    required this.name,
    required this.runtime,
    required this.image,
    required this.tag,
    required this.status,
    required this.port,
    required this.cpu,
    required this.memoryMb,
    required this.volume,
    required this.extensions,
    required this.pkgMirror,
    required this.configVersion,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final String runtime;
  final String image;
  final String tag;
  final String status;
  final int? port;
  final double? cpu;
  final int? memoryMb;
  final String volume;
  final List<String> extensions;
  final String pkgMirror;
  final int configVersion;
  final int createdAt;
  final int updatedAt;

  factory RuntimeEnvironment.fromJson(Map<String, dynamic> json) =>
      RuntimeEnvironment(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        runtime: json['runtime'] as String? ?? '',
        image: json['image'] as String? ?? '',
        tag: json['tag'] as String? ?? '',
        status: json['status'] as String? ?? 'unknown',
        port: (json['port'] as num?)?.toInt(),
        cpu: (json['cpu'] as num?)?.toDouble(),
        memoryMb: (json['memory_mb'] as num?)?.toInt(),
        volume: json['volume'] as String? ?? '',
        extensions: ((json['extensions'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        pkgMirror: json['pkg_mirror'] as String? ?? '',
        configVersion: (json['config_version'] as num?)?.toInt() ?? 1,
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
      );

  String get imageRef => tag.isEmpty ? image : '$image:$tag';

  bool get running => status == 'running';
}

class RuntimeConfigFile {
  const RuntimeConfigFile({required this.path, required this.content});

  final String path;
  final String content;

  factory RuntimeConfigFile.fromJson(Map<String, dynamic> json) =>
      RuntimeConfigFile(
        path: json['path'] as String? ?? '',
        content: json['content'] as String? ?? '',
      );
}
