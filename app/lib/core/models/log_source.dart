class LogSource {
  const LogSource({
    required this.id,
    required this.label,
    required this.path,
    required this.available,
  });

  final String id;
  final String label;
  final String path;
  final bool available;

  factory LogSource.fromJson(Map<String, dynamic> json) => LogSource(
    id: json['id'] as String? ?? '',
    label: json['label'] as String? ?? '',
    path: json['path'] as String? ?? '',
    available: json['available'] as bool? ?? false,
  );
}
