class FileEntry {
  const FileEntry({
    required this.name,
    required this.path,
    required this.kind,
    required this.size,
    required this.mode,
    required this.uid,
    required this.gid,
    required this.modifiedMs,
    required this.symlink,
  });

  final String name;
  final String path;
  final String kind;
  final int size;
  final String mode;
  final int uid;
  final int gid;
  final int modifiedMs;
  final bool symlink;

  bool get isDir => kind == 'dir';

  factory FileEntry.fromJson(Map<String, dynamic> json) => FileEntry(
    name: json['name'] as String? ?? '',
    path: json['path'] as String? ?? '',
    kind: json['kind'] as String? ?? 'file',
    size: (json['size'] as num?)?.toInt() ?? 0,
    mode: json['mode'] as String? ?? '-',
    uid: (json['uid'] as num?)?.toInt() ?? 0,
    gid: (json['gid'] as num?)?.toInt() ?? 0,
    modifiedMs: (json['modified_ms'] as num?)?.toInt() ?? 0,
    symlink: json['symlink'] as bool? ?? false,
  );
}

class FileContent {
  const FileContent({
    required this.path,
    required this.size,
    required this.encoding,
    required this.truncated,
    required this.content,
  });

  final String path;
  final int size;
  final String encoding;
  final bool truncated;
  final String content;

  factory FileContent.fromJson(Map<String, dynamic> json) => FileContent(
    path: json['path'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    encoding: json['encoding'] as String? ?? 'utf8',
    truncated: json['truncated'] as bool? ?? false,
    content: json['content'] as String? ?? '',
  );
}
