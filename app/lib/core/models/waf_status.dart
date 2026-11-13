class WafStatus {
  const WafStatus({
    required this.installed,
    required this.running,
    required this.version,
    required this.mode,
    required this.listenHost,
    required this.listenPort,
    required this.upstreamHost,
    required this.upstreamPort,
    required this.binary,
    required this.configPath,
    required this.logPath,
    required this.goAvailable,
    required this.crs,
    required this.message,
    required this.riskEnabled,
    required this.riskRunning,
    required this.riskPort,
    required this.riskBinary,
    required this.riskLogPath,
    required this.typesafeEnabled,
    required this.typesafeEndpoint,
    required this.typesafeModel,
    required this.typesafeThreshold,
    required this.typesafeTimeoutMs,
    required this.typesafeFailOpen,
    required this.typesafeKeyConfigured,
    required this.geoipRules,
    required this.geositeRules,
    required this.routes,
    required this.tlsEnabled,
    required this.tlsMode,
    required this.tlsEmail,
  });

  final bool installed;
  final bool running;
  final String version;
  final String mode;
  final String listenHost;
  final int listenPort;
  final String upstreamHost;
  final int upstreamPort;
  final String binary;
  final String configPath;
  final String logPath;
  final bool goAvailable;
  final String crs;
  final String message;
  final bool riskEnabled;
  final bool riskRunning;
  final int riskPort;
  final String riskBinary;
  final String riskLogPath;
  final bool typesafeEnabled;
  final String typesafeEndpoint;
  final String typesafeModel;
  final double typesafeThreshold;
  final int typesafeTimeoutMs;
  final bool typesafeFailOpen;
  final bool typesafeKeyConfigured;
  final List<GeoRule> geoipRules;
  final List<GeoRule> geositeRules;
  final List<WafRoute> routes;
  final bool tlsEnabled;
  final String tlsMode;
  final String tlsEmail;

  factory WafStatus.fromJson(Map<String, dynamic> json) => WafStatus(
    installed: json['installed'] as bool? ?? false,
    running: json['running'] as bool? ?? false,
    version: json['version'] as String? ?? '',
    mode: json['mode'] as String? ?? 'detect',
    listenHost: json['listen_host'] as String? ?? '0.0.0.0',
    listenPort: (json['listen_port'] as num?)?.toInt() ?? 0,
    upstreamHost: json['upstream_host'] as String? ?? '127.0.0.1',
    upstreamPort: (json['upstream_port'] as num?)?.toInt() ?? 0,
    binary: json['binary'] as String? ?? '',
    configPath: json['config_path'] as String? ?? '',
    logPath: json['log_path'] as String? ?? '',
    goAvailable: json['go_available'] as bool? ?? false,
    crs: json['crs'] as String? ?? '',
    message: json['message'] as String? ?? '',
    riskEnabled: json['risk_enabled'] as bool? ?? true,
    riskRunning: json['risk_running'] as bool? ?? false,
    riskPort: (json['risk_port'] as num?)?.toInt() ?? 18092,
    riskBinary: json['risk_binary'] as String? ?? '',
    riskLogPath: json['risk_log_path'] as String? ?? '',
    typesafeEnabled: json['typesafe_enabled'] as bool? ?? false,
    typesafeEndpoint:
        json['typesafe_endpoint'] as String? ??
        'https://api.typesafe.ai/v1/systemone',
    typesafeModel: json['typesafe_model'] as String? ?? 'jev-latest',
    typesafeThreshold: (json['typesafe_threshold'] as num?)?.toDouble() ?? 0.85,
    typesafeTimeoutMs: (json['typesafe_timeout_ms'] as num?)?.toInt() ?? 800,
    typesafeFailOpen: json['typesafe_fail_open'] as bool? ?? true,
    typesafeKeyConfigured: json['typesafe_key_configured'] as bool? ?? false,
    geoipRules: ((json['geoip_rules'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GeoRule.fromJson)
        .toList(),
    geositeRules: ((json['geosite_rules'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GeoRule.fromJson)
        .toList(),
    routes: ((json['routes'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(WafRoute.fromJson)
        .toList(),
    tlsEnabled: json['tls_enabled'] as bool? ?? false,
    tlsMode: json['tls_mode'] as String? ?? 'internal',
    tlsEmail: json['tls_email'] as String? ?? '',
  );
}

class GeoRule {
  const GeoRule({required this.tag, required this.action});
  final String tag;
  final String action;

  factory GeoRule.fromJson(Map<String, dynamic> json) => GeoRule(
    tag: json['tag'] as String? ?? '',
    action: json['action'] as String? ?? 'deny',
  );
  Map<String, dynamic> toJson() => {'tag': tag, 'action': action};
}

class GeoCountry {
  const GeoCountry({required this.code, required this.name});
  final String code;
  final String name;
  factory GeoCountry.fromJson(Map<String, dynamic> json) => GeoCountry(
    code: json['code'] as String? ?? '',
    name: json['name'] as String? ?? '',
  );
}

class GeoSiteService {
  const GeoSiteService({
    required this.id,
    required this.name,
    required this.category,
    required this.src,
  });
  final String id;
  final String name;
  final String category;
  final String src;
  factory GeoSiteService.fromJson(Map<String, dynamic> json) => GeoSiteService(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    category: json['category'] as String? ?? '',
    src: json['src'] as String? ?? '',
  );
}

class GeoCatalog {
  const GeoCatalog({
    required this.countries,
    required this.geosite,
    required this.updatedAt,
  });
  final List<GeoCountry> countries;
  final List<GeoSiteService> geosite;
  final String updatedAt;
  factory GeoCatalog.fromJson(Map<String, dynamic> json) => GeoCatalog(
    countries: ((json['countries'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GeoCountry.fromJson)
        .toList(),
    geosite: ((json['geosite'] as List?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(GeoSiteService.fromJson)
        .toList(),
    updatedAt: json['updated_at'] as String? ?? '',
  );
}

class WafRoute {
  const WafRoute({
    required this.name,
    required this.hosts,
    required this.upstreamHost,
    required this.upstreamPort,
    required this.mode,
  });
  final String name;
  final List<String> hosts;
  final String upstreamHost;
  final int upstreamPort;
  final String mode;

  factory WafRoute.fromJson(Map<String, dynamic> json) => WafRoute(
    name: json['name'] as String? ?? '',
    hosts: ((json['hosts'] as List?) ?? const []).whereType<String>().toList(),
    upstreamHost: json['upstream_host'] as String? ?? '',
    upstreamPort: (json['upstream_port'] as num?)?.toInt() ?? 0,
    mode: json['mode'] as String? ?? 'inherit',
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'hosts': hosts,
    'upstream_host': upstreamHost,
    'upstream_port': upstreamPort,
    'mode': mode,
  };
}
