class SiteInfo {
  const SiteInfo({
    required this.name,
    required this.path,
    required this.enabled,
    required this.domains,
    required this.root,
    required this.listen,
  });

  final String name;
  final String path;
  final bool enabled;
  final List<String> domains;
  final String root;
  final String listen;

  factory SiteInfo.fromJson(Map<String, dynamic> json) => SiteInfo(
    name: json['name'] as String? ?? '',
    path: json['path'] as String? ?? '',
    enabled: json['enabled'] as bool? ?? false,
    domains: ((json['domains'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    root: json['root'] as String? ?? '',
    listen: json['listen'] as String? ?? '',
  );
}

class SiteList {
  const SiteList({
    required this.available,
    required this.directory,
    required this.sites,
  });

  final bool available;
  final String directory;
  final List<SiteInfo> sites;

  factory SiteList.fromJson(Map<String, dynamic> json) => SiteList(
    available: json['available'] as bool? ?? false,
    directory: json['dir'] as String? ?? '',
    sites: ((json['sites'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SiteInfo.fromJson)
        .toList(),
  );
}
