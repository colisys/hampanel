class ServiceInfo {
  const ServiceInfo({
    required this.unit,
    required this.load,
    required this.active,
    required this.sub,
    required this.description,
  });

  final String unit;
  final String load;
  final String active;
  final String sub;
  final String description;

  bool get running => active == 'active';

  factory ServiceInfo.fromJson(Map<String, dynamic> json) => ServiceInfo(
    unit: json['unit'] as String? ?? '-',
    load: json['load'] as String? ?? '-',
    active: json['active'] as String? ?? '-',
    sub: json['sub'] as String? ?? '-',
    description: json['description'] as String? ?? '',
  );
}
