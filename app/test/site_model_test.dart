import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hampanel/features/sites/webhook_credential.dart';
import 'package:hampanel/features/sites/cron_tls_fields.dart';
import 'package:hampanel/core/models/site.dart';

void main() {
  test('cron TLS accepts only safe absolute file paths', () {
    expect(isWebhookTlsPath('/etc/certs/hooks/fullchain.pem'), isTrue);
    for (final invalid in [
      '',
      '/',
      '/etc/certs/',
      'key.pem',
      '-----BEGIN PRIVATE KEY-----',
      '/key\nline',
      '/path with spaces',
      '/key;other',
      r'/keys/$host',
      '/${'证' * 700}',
    ]) {
      expect(isWebhookTlsPath(invalid), isFalse);
    }
  });

  testWidgets('existing certificate choice fills both editable paths', (
    tester,
  ) async {
    var cert = '';
    var keyPath = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (_, update) => CronTlsFields(
              certificate: cert,
              privateKeyPath: keyPath,
              sites: const [
                Site(
                  name: 'shared',
                  tls: SiteTls(
                    enabled: true,
                    certificate: '/certs/fullchain.pem',
                    key: '/certs/key.pem',
                  ),
                ),
                Site(name: 'missing'),
              ],
              onChanged: (c, k) => update(() {
                cert = c;
                keyPath = k;
              }),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择已有站点证书'));
    await tester.pumpAndSettle();
    expect(find.text('missing'), findsNothing);
    await tester.tap(find.text('shared'));
    await tester.pumpAndSettle();
    expect(find.text('/certs/fullchain.pem'), findsOneWidget);
    expect(find.text('/certs/key.pem'), findsOneWidget);
    await tester.enterText(
      find.byType(TextFormField).last,
      '/certs/new-key.pem',
    );
    expect([cert, keyPath], ['/certs/fullchain.pem', '/certs/new-key.pem']);
  });

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
        users: [SiteBasicUser(username: 'admin', passwordHash: r'$apr1$hash')],
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

  test('webhook keeps its kind and fixed proxy upstream', () {
    const origin = 'https://hooks.example.com:8443';
    final site = Site.fromJson({
      'kind': 'webhook',
      'proxy': {
        'upstreams': [
          {'address': origin},
        ],
      },
    });
    expect(site.summaryTarget, origin);
    expect(site.toJson()['kind'], 'webhook');
    expect(site.toJson()['proxy']['upstreams'], [
      {'address': origin, 'weight': 1},
    ]);
  });

  test('webhook update sends only editable options and a single upstream', () {
    final body = webhookUpdateJson(
      name: 'hook',
      enabled: true,
      domains: ['hook.example'],
      listen: 8080,
      origin: 'https://receiver',
      tls: const SiteTls(),
    );
    expect(body.keys.toSet(), {
      'name',
      'enabled',
      'kind',
      'domains',
      'listen',
      'tls',
      'proxy',
    });
    expect(body['proxy'], {
      'upstreams': [
        {'address': 'https://receiver', 'weight': 1},
      ],
    });
  });

  test('webhook accepts only a single HTTP(S) origin', () {
    for (final value in [
      'https://example.com',
      'http://127.0.0.1:3000',
      'http://[::1]:80',
    ]) {
      expect(isWebhookOrigin(value), isTrue, reason: value);
    }
    for (final value in [
      '',
      'localhost:3000',
      'ftp://host',
      'https://user@host',
      'https://host/a',
      'https://host?x=1',
      'https://host#f',
      'http://host:65536',
      'http://host:0',
      'http://host:',
      'http://host:+1',
      'http://host:000001',
      'http://UNix:80',
      'http://a..b',
      'http://-a',
      'http://a-',
      'http://a.',
      'http://a/',
      'http://[abcd]',
      'http://[1::2::3]',
      'http://host\n',
      'http://${'a' * 64}',
      'http://${List.filled(4, 'a' * 63).join('.')}',
      ' https://host',
      'https://one\nhttps://two',
    ]) {
      expect(isWebhookOrigin(value), isFalse, reason: value);
    }
  });

  test('webhook capabilities default closed and cron binding round trips', () {
    expect(parseWebhookTargets({}), isEmpty);
    final detail = SiteDetail.fromJson({
      'webhook_targets': ['upstream', 'cron', 'unknown'],
      'site': {
        'kind': 'webhook',
        'webhook': {'target': 'cron', 'cron_id': 'job-1'},
      },
    });
    expect(detail.webhookTargets, ['upstream', 'cron']);
    expect(detail.site.webhook?.cronId, 'job-1');
    expect(detail.site.summaryTarget, 'Cron · job-1');
    expect(detail.site.toJson()['webhook'], {
      'target': 'cron',
      'cron_id': 'job-1',
    });
    final body = webhookUpdateJson(
      name: 'hook',
      enabled: true,
      domains: ['example.com'],
      listen: 80,
      origin: '',
      webhook: const SiteWebhook(target: 'cron', cronId: 'job-1'),
      tls: const SiteTls(),
    );
    expect(body['webhook'], {'target': 'cron', 'cron_id': 'job-1'});
  });

  testWidgets('one-time webhook credential displays only response fields', (
    tester,
  ) async {
    expect(hasWebhookCredential({}), isFalse);
    expect(hasWebhookCredential({'webhook_url': 'https://hook'}), isFalse);
    const response = {
      'webhook_url': 'https://hooks.example/hook/site/secret',
      'webhook_token': 'secret',
    };
    expect(hasWebhookCredential(response), isTrue);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showWebhookCredential(context, response),
              child: const Text('显示凭据'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('显示凭据'));
    await tester.pumpAndSettle();
    expect(find.text('Webhook 凭据（仅显示一次）'), findsOneWidget);
    expect(
      find.textContaining('https://hooks.example/hook/site/secret'),
      findsOneWidget,
    );
    await tester.tap(find.text('已保存'));
    await tester.pumpAndSettle();
    expect(find.text('Webhook 凭据（仅显示一次）'), findsNothing);
  });

  test('tcp and udp sites expose their upstream target', () {
    const tcp = Site(
      kind: 'tcp_proxy',
      proxy: SiteProxy(upstreams: [SiteUpstream(address: '127.0.0.1:9000')]),
    );
    const udp = Site(
      kind: 'udp_proxy',
      proxy: SiteProxy(upstreams: [SiteUpstream(address: '127.0.0.1:9001')]),
    );
    expect(tcp.summaryTarget, '127.0.0.1:9000');
    expect(udp.summaryTarget, '127.0.0.1:9001');
  });
}
