import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/models/site.dart';

void main() {
  test('site configuration JSON round trip', () {
    const site = Site(
      name: 'demo',
      kind: 'reverse_proxy',
      enabled: true,
      domains: ['example.com'],
      listen: 8080,
      ipv6: true,
      root: '/var/www/demo',
      runDir: '/var/www/demo',
      index: ['index.html'],
      accessLog: '/var/log/nginx/demo.access.log',
      errorLog: '/var/log/nginx/demo.error.log',
      clientMaxBodySize: '16m',
      runtimeId: 'rt-1',
      tls: SiteTls(
        enabled: true,
        certificate: '/etc/ssl/cert.pem',
        key: '/etc/ssl/key.pem',
        acmeEmail: 'ops@example.com',
        redirectHttp: true,
        hsts: true,
      ),
      rateLimit: SiteRateLimit(
        enabled: true,
        rps: 20,
        burst: 40,
        connections: 5,
      ),
      basicAuth: SiteBasicAuth(
        enabled: true,
        users: [
          SiteBasicUser(username: 'admin', passwordHash: r'$apr1$hash'),
        ],
      ),
      cors: SiteCors(
        enabled: true,
        origins: ['https://app.example.com'],
        methods: ['GET', 'POST'],
        headers: ['Content-Type'],
        credentials: true,
      ),
      hotlink: SiteHotlink(
        enabled: true,
        allowEmptyReferer: false,
        extensions: ['png', 'jpg'],
      ),
      redirects: [SiteRedirect(from: '/old', to: '/new', code: 301)],
      rewrites: [
        SiteRewrite(
          pattern: r'^/legacy/(.*)$',
          replacement: r'/$1',
          flag: 'last',
        ),
      ],
      proxy: SiteProxy(
        upstreams: [SiteUpstream(address: '127.0.0.1:3000', weight: 2)],
        loadBalance: 'least_conn',
        websocket: true,
        preserveHost: true,
        headers: [SiteProxyHeader(name: 'X-Real-IP', value: r'$remote_addr')],
      ),
      realIp: SiteRealIp(
        enabled: true,
        header: 'X-Real-IP',
        trusted: ['10.0.0.0/8'],
      ),
      custom: SiteCustom(enabled: true, content: 'server { listen 8099; }'),
      createdAt: 1,
      updatedAt: 2,
    );

    final json = site.toJson();
    final parsed = Site.fromJson(json);
    expect(parsed.toJson(), equals(json));
    expect(parsed.tls.hsts, isTrue);
    expect(parsed.rateLimit.connections, 5);
    expect(parsed.basicAuth.users.single.username, 'admin');
    expect(parsed.cors.credentials, isTrue);
    expect(parsed.hotlink.allowEmptyReferer, isFalse);
    expect(parsed.proxy.upstreams.single.weight, 2);
    expect(parsed.realIp.trusted.single, '10.0.0.0/8');
    expect(parsed.custom.content, contains('8099'));

    final detail = SiteDetail.fromJson({
      'site': json,
      'config': 'server {}',
      'webserver': 'nginx',
    });
    expect(detail.site.name, 'demo');
    expect(detail.webserver, 'nginx');

    final list = SiteList.fromJson({
      'available': true,
      'supported': true,
      'webserver': 'nginx',
      'dir': '/etc/nginx/conf.d',
      'sites': [json],
    });
    expect(list.sites.single.name, 'demo');
  });

  test('tcp and udp sites expose their upstream target', () {
    const tcp = Site(
      kind: 'tcp_proxy',
      proxy: SiteProxy(
        upstreams: [SiteUpstream(address: '127.0.0.1:9000')],
      ),
    );
    const udp = Site(
      kind: 'udp_proxy',
      proxy: SiteProxy(
        upstreams: [SiteUpstream(address: '127.0.0.1:9001')],
      ),
    );
    expect(tcp.summaryTarget, '127.0.0.1:9000');
    expect(udp.summaryTarget, '127.0.0.1:9001');
  });
}
