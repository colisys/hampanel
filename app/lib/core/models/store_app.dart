class StoreParam {
  const StoreParam({
    required this.key,
    required this.label,
    required this.kind,
    required this.defaultValue,
    required this.secret,
  });

  final String key;
  final String label;
  final String kind;
  final String defaultValue;
  final bool secret;

  bool get isPort => kind == 'port';
  bool get isPassword => kind == 'password';

  factory StoreParam.fromJson(Map<String, dynamic> json) => StoreParam(
    key: json['key'] as String? ?? '',
    label: json['label'] as String? ?? '',
    kind: json['kind'] as String? ?? 'text',
    defaultValue: json['default'] as String? ?? '',
    secret: json['secret'] as bool? ?? false,
  );
}

class StoreApp {
  const StoreApp({
    required this.slug,
    required this.name,
    required this.description,
    required this.category,
    required this.icon,
    required this.installed,
    required this.params,
  });

  final String slug;
  final String name;
  final String description;
  final String category;
  final String icon;
  final bool installed;
  final List<StoreParam> params;

  factory StoreApp.fromJson(Map<String, dynamic> json) => StoreApp(
    slug: json['slug'] as String? ?? '',
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
    category: json['category'] as String? ?? '',
    icon: json['icon'] as String? ?? '',
    installed: json['installed'] as bool? ?? false,
    params: ((json['params'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(StoreParam.fromJson)
        .toList(),
  );
}
