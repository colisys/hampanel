class RecycleEntry {
  const RecycleEntry({
    required this.id,
    required this.originalPath,
    required this.name,
    required this.kind,
    required this.size,
    required this.deletedAt,
  });

  final String id;
  final String originalPath;
  final String name;
  final String kind;
  final int size;
  final int deletedAt;

  factory RecycleEntry.fromJson(Map<String, dynamic> json) => RecycleEntry(
        id: json['id'] as String? ?? '',
        originalPath: json['original_path'] as String? ?? '',
        name: json['name'] as String? ?? '',
        kind: json['kind'] as String? ?? 'file',
        size: (json['size'] as num?)?.toInt() ?? 0,
        deletedAt: (json['deleted_at'] as num?)?.toInt() ?? 0,
      );
}

class FileVersion {
  const FileVersion({
    required this.id,
    required this.createdAt,
    required this.size,
  });

  final String id;
  final int createdAt;
  final int size;

  factory FileVersion.fromJson(Map<String, dynamic> json) => FileVersion(
        id: json['id'] as String? ?? '',
        createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
        size: (json['size'] as num?)?.toInt() ?? 0,
      );
}
