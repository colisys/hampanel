class SiteTls {
  const SiteTls({
    this.enabled = false,
    this.certificate = '',
    this.key = '',
    this.acmeEmail = '',
    this.redirectHttp = true,
    this.hsts = false,
  });

  final bool enabled;
  final String certificate;
  final String key;
  final String acmeEmail;
  final bool redirectHttp;
  final bool hsts;

  factory SiteTls.fromJson(Map<String, dynamic>? json) => SiteTls(
    enabled: json?['enabled'] as bool? ?? false,
    certificate: json?['certificate'] as String? ?? '',
    key: json?['key'] as String? ?? '',
    acmeEmail: json?['acme_email'] as String? ?? '',
    redirectHttp: json?['redirect_http'] as bool? ?? true,
    hsts: json?['hsts'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'certificate': certificate,
    'key': key,
    'acme_email': acmeEmail,
    'redirect_http': redirectHttp,
    'hsts': hsts,
  };
}

class SiteRateLimit {
  const SiteRateLimit({
    this.enabled = false,
    this.rps = 10,
    this.burst = 20,
    this.connections = 0,
  });

  final bool enabled;
  final int rps;
  final int burst;
  final int connections;

  factory SiteRateLimit.fromJson(Map<String, dynamic>? json) => SiteRateLimit(
    enabled: json?['enabled'] as bool? ?? false,
    rps: (json?['rps'] as num?)?.toInt() ?? 10,
    burst: (json?['burst'] as num?)?.toInt() ?? 20,
    connections: (json?['connections'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'rps': rps,
    'burst': burst,
    'connections': connections,
  };
}

class SiteBasicUser {
  const SiteBasicUser({this.username = '', this.passwordHash = ''});

  final String username;
  final String passwordHash;

  factory SiteBasicUser.fromJson(Map<String, dynamic>? json) => SiteBasicUser(
    username: json?['username'] as String? ?? '',
    passwordHash: json?['password_hash'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {
    'username': username,
    'password_hash': passwordHash,
  };
}

class SiteBasicAuth {
  const SiteBasicAuth({this.enabled = false, this.users = const []});

  final bool enabled;
  final List<SiteBasicUser> users;

  factory SiteBasicAuth.fromJson(Map<String, dynamic>? json) => SiteBasicAuth(
    enabled: json?['enabled'] as bool? ?? false,
    users: ((json?['users'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SiteBasicUser.fromJson)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'users': [for (final user in users) user.toJson()],
  };
}

class SiteCors {
  const SiteCors({
    this.enabled = false,
    this.origins = const [],
    this.methods = const [],
    this.headers = const [],
    this.credentials = false,
  });

  final bool enabled;
  final List<String> origins;
  final List<String> methods;
  final List<String> headers;
  final bool credentials;

  factory SiteCors.fromJson(Map<String, dynamic>? json) => SiteCors(
    enabled: json?['enabled'] as bool? ?? false,
    origins: ((json?['origins'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    methods: ((json?['methods'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    headers: ((json?['headers'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    credentials: json?['credentials'] as bool? ?? false,
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'origins': origins,
    'methods': methods,
    'headers': headers,
    'credentials': credentials,
  };
}

class SiteHotlink {
  const SiteHotlink({
    this.enabled = false,
    this.allowEmptyReferer = true,
    this.extensions = const [],
  });

  final bool enabled;
  final bool allowEmptyReferer;
  final List<String> extensions;

  factory SiteHotlink.fromJson(Map<String, dynamic>? json) => SiteHotlink(
    enabled: json?['enabled'] as bool? ?? false,
    allowEmptyReferer: json?['allow_empty_referer'] as bool? ?? true,
    extensions: ((json?['extensions'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'allow_empty_referer': allowEmptyReferer,
    'extensions': extensions,
  };
}

class SiteRedirect {
  const SiteRedirect({this.from = '', this.to = '', this.code = 301});

  final String from;
  final String to;
  final int code;

  factory SiteRedirect.fromJson(Map<String, dynamic>? json) => SiteRedirect(
    from: json?['from'] as String? ?? '',
    to: json?['to'] as String? ?? '',
    code: (json?['code'] as num?)?.toInt() ?? 301,
  );

  Map<String, dynamic> toJson() => {'from': from, 'to': to, 'code': code};
}

class SiteRewrite {
  const SiteRewrite({
    this.pattern = '',
    this.replacement = '',
    this.flag = 'last',
  });

  final String pattern;
  final String replacement;
  final String flag;

  factory SiteRewrite.fromJson(Map<String, dynamic>? json) => SiteRewrite(
    pattern: json?['pattern'] as String? ?? '',
    replacement: json?['replacement'] as String? ?? '',
    flag: json?['flag'] as String? ?? 'last',
  );

  Map<String, dynamic> toJson() => {
    'pattern': pattern,
    'replacement': replacement,
    'flag': flag,
  };
}

class SiteUpstream {
  const SiteUpstream({this.address = '', this.weight = 1});

  final String address;
  final int weight;

  factory SiteUpstream.fromJson(Map<String, dynamic>? json) => SiteUpstream(
    address: json?['address'] as String? ?? '',
    weight: (json?['weight'] as num?)?.toInt() ?? 1,
  );

  Map<String, dynamic> toJson() => {'address': address, 'weight': weight};
}

class SiteProxyHeader {
  const SiteProxyHeader({this.name = '', this.value = ''});

  final String name;
  final String value;

  factory SiteProxyHeader.fromJson(Map<String, dynamic>? json) =>
      SiteProxyHeader(
        name: json?['name'] as String? ?? '',
        value: json?['value'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'value': value};
}

class SiteProxy {
  const SiteProxy({
    this.upstreams = const [],
    this.loadBalance = 'round_robin',
    this.websocket = true,
    this.preserveHost = true,
    this.headers = const [],
  });

  final List<SiteUpstream> upstreams;
  final String loadBalance;
  final bool websocket;
  final bool preserveHost;
  final List<SiteProxyHeader> headers;

  factory SiteProxy.fromJson(Map<String, dynamic>? json) => SiteProxy(
    upstreams: ((json?['upstreams'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SiteUpstream.fromJson)
        .toList(),
    loadBalance: json?['load_balance'] as String? ?? 'round_robin',
    websocket: json?['websocket'] as bool? ?? true,
    preserveHost: json?['preserve_host'] as bool? ?? true,
    headers: ((json?['headers'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SiteProxyHeader.fromJson)
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'upstreams': [for (final upstream in upstreams) upstream.toJson()],
    'load_balance': loadBalance,
    'websocket': websocket,
    'preserve_host': preserveHost,
    'headers': [for (final header in headers) header.toJson()],
  };
}

class SiteRealIp {
  const SiteRealIp({
    this.enabled = false,
    this.header = 'X-Forwarded-For',
    this.trusted = const [],
  });

  final bool enabled;
  final String header;
  final List<String> trusted;

  factory SiteRealIp.fromJson(Map<String, dynamic>? json) => SiteRealIp(
    enabled: json?['enabled'] as bool? ?? false,
    header: json?['header'] as String? ?? 'X-Forwarded-For',
    trusted: ((json?['trusted'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'header': header,
    'trusted': trusted,
  };
}

class SiteCustom {
  const SiteCustom({this.enabled = false, this.content = ''});

  final bool enabled;
  final String content;

  factory SiteCustom.fromJson(Map<String, dynamic>? json) => SiteCustom(
    enabled: json?['enabled'] as bool? ?? false,
    content: json?['content'] as String? ?? '',
  );

  Map<String, dynamic> toJson() => {'enabled': enabled, 'content': content};
}

class Site {
  const Site({
    this.name = '',
    this.kind = 'static',
    this.enabled = true,
    this.domains = const [],
    this.listen = 80,
    this.ipv6 = true,
    this.root = '',
    this.runDir = '',
    this.index = const [],
    this.accessLog = '',
    this.errorLog = '',
    this.clientMaxBodySize = '',
    this.runtimeId = '',
    this.tls = const SiteTls(),
    this.rateLimit = const SiteRateLimit(),
    this.basicAuth = const SiteBasicAuth(),
    this.cors = const SiteCors(),
    this.hotlink = const SiteHotlink(),
    this.redirects = const [],
    this.rewrites = const [],
    this.proxy = const SiteProxy(),
    this.realIp = const SiteRealIp(),
    this.custom = const SiteCustom(),
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String name;
  final String kind;
  final bool enabled;
  final List<String> domains;
  final int listen;
  final bool ipv6;
  final String root;
  final String runDir;
  final List<String> index;
  final String accessLog;
  final String errorLog;
  final String clientMaxBodySize;
  final String runtimeId;
  final SiteTls tls;
  final SiteRateLimit rateLimit;
  final SiteBasicAuth basicAuth;
  final SiteCors cors;
  final SiteHotlink hotlink;
  final List<SiteRedirect> redirects;
  final List<SiteRewrite> rewrites;
  final SiteProxy proxy;
  final SiteRealIp realIp;
  final SiteCustom custom;
  final int createdAt;
  final int updatedAt;

  factory Site.fromJson(Map<String, dynamic> json) => Site(
    name: json['name'] as String? ?? '',
    kind: json['kind'] as String? ?? 'static',
    enabled: json['enabled'] as bool? ?? true,
    domains: ((json['domains'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    listen: (json['listen'] as num?)?.toInt() ?? 80,
    ipv6: json['ipv6'] as bool? ?? true,
    root: json['root'] as String? ?? '',
    runDir: json['run_dir'] as String? ?? '',
    index: ((json['index'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    accessLog: json['access_log'] as String? ?? '',
    errorLog: json['error_log'] as String? ?? '',
    clientMaxBodySize: json['client_max_body_size'] as String? ?? '',
    runtimeId: json['runtime_id'] as String? ?? '',
    tls: SiteTls.fromJson(json['tls'] as Map<String, dynamic>?),
    rateLimit: SiteRateLimit.fromJson(
      json['rate_limit'] as Map<String, dynamic>?,
    ),
    basicAuth: SiteBasicAuth.fromJson(
      json['basic_auth'] as Map<String, dynamic>?,
    ),
    cors: SiteCors.fromJson(json['cors'] as Map<String, dynamic>?),
    hotlink: SiteHotlink.fromJson(json['hotlink'] as Map<String, dynamic>?),
    redirects: ((json['redirects'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SiteRedirect.fromJson)
        .toList(),
    rewrites: ((json['rewrites'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(SiteRewrite.fromJson)
        .toList(),
    proxy: SiteProxy.fromJson(json['proxy'] as Map<String, dynamic>?),
    realIp: SiteRealIp.fromJson(json['real_ip'] as Map<String, dynamic>?),
    custom: SiteCustom.fromJson(json['custom'] as Map<String, dynamic>?),
    createdAt: (json['created_at'] as num?)?.toInt() ?? 0,
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );

  Map<String, dynamic> toJson() => {
    'name': name,
    'kind': kind,
    'enabled': enabled,
    'domains': domains,
    'listen': listen,
    'ipv6': ipv6,
    'root': root,
    'run_dir': runDir,
    'index': index,
    'access_log': accessLog,
    'error_log': errorLog,
    'client_max_body_size': clientMaxBodySize,
    'runtime_id': runtimeId,
    'tls': tls.toJson(),
    'rate_limit': rateLimit.toJson(),
    'basic_auth': basicAuth.toJson(),
    'cors': cors.toJson(),
    'hotlink': hotlink.toJson(),
    'redirects': [for (final redirect in redirects) redirect.toJson()],
    'rewrites': [for (final rewrite in rewrites) rewrite.toJson()],
    'proxy': proxy.toJson(),
    'real_ip': realIp.toJson(),
    'custom': custom.toJson(),
    'created_at': createdAt,
    'updated_at': updatedAt,
  };

  String get summaryTarget {
    if (kind == 'reverse_proxy' || kind == 'runtime' || kind == 'tcp_proxy' || kind == 'udp_proxy') {
      return proxy.upstreams.map((item) => item.address).join(', ');
    }
    return root;
  }
}

class SiteList {
  const SiteList({
    required this.available,
    required this.supported,
    required this.webserver,
    required this.directory,
    required this.sites,
    required this.message,
  });

  final bool available;
  final bool supported;
  final String webserver;
  final String directory;
  final List<Site> sites;
  final String message;

  factory SiteList.fromJson(Map<String, dynamic> json) => SiteList(
    available: json['available'] as bool? ?? false,
    supported: json['supported'] as bool? ?? true,
    webserver: json['webserver'] as String? ?? '',
    directory: json['dir'] as String? ?? '',
    sites: ((json['sites'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(Site.fromJson)
        .toList(),
    message: json['message'] as String? ?? '',
  );
}

class SiteDetail {
  const SiteDetail({
    required this.site,
    required this.config,
    required this.configError,
    required this.webserver,
  });

  final Site site;
  final String config;
  final String configError;
  final String webserver;

  factory SiteDetail.fromJson(Map<String, dynamic> json) => SiteDetail(
    site: Site.fromJson((json['site'] as Map<String, dynamic>?) ?? const {}),
    config: json['config'] as String? ?? '',
    configError: json['config_error'] as String? ?? '',
    webserver: json['webserver'] as String? ?? '',
  );
}
