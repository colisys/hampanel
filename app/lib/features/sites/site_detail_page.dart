import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/site.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/remote_picker.dart';
import '../../ui/log_page.dart';
import '../../ui/widgets.dart';
import 'webhook_credential.dart';
import 'cron_tls_fields.dart';

class SiteDetailPage extends StatefulWidget {
  const SiteDetailPage({
    super.key,
    required this.api,
    required this.siteName,
    this.sites = const [],
  });

  final List<Site> sites;
  final ApiClient api;
  final String siteName;

  @override
  State<SiteDetailPage> createState() => _SiteDetailPageState();
}

class _SiteDetailPageState extends State<SiteDetailPage> {
  final _domains = TextEditingController();
  final _listen = TextEditingController();
  final _root = TextEditingController();
  final _runDir = TextEditingController();
  final _index = TextEditingController();
  final _accessLog = TextEditingController();
  final _errorLog = TextEditingController();
  final _bodySize = TextEditingController();
  final _upstreams = TextEditingController();
  final _proxyHeaders = TextEditingController();
  final _redirects = TextEditingController();
  final _rewrites = TextEditingController();
  final _corsOrigins = TextEditingController();
  final _corsMethods = TextEditingController();
  final _corsHeaders = TextEditingController();
  final _hotlinkExtensions = TextEditingController();
  final _realIpHeader = TextEditingController();
  final _realIpTrusted = TextEditingController();
  final _rateRps = TextEditingController();
  final _rateBurst = TextEditingController();
  final _rateConnections = TextEditingController();
  final _custom = TextEditingController();

  SiteDetail? _detail;
  Site? _site;
  String? _error;
  bool _loading = true;
  bool _saving = false;

  String _kind = 'static';
  bool _enabled = true;
  bool _ipv6 = true;
  String _runtimeId = '';
  String _loadBalance = 'round_robin';
  bool _proxyWebsocket = true;
  bool _proxyPreserveHost = true;
  bool _tlsEnabled = false;
  bool _tlsRedirect = true;
  bool _tlsHsts = false;
  String _tlsCertificate = '';
  String _tlsKey = '';
  bool _basicEnabled = false;
  List<String> _basicUsers = const [];
  bool _corsEnabled = false;
  bool _corsCredentials = false;
  bool _hotlinkEnabled = false;
  bool _hotlinkAllowEmpty = true;
  bool _realIpEnabled = false;
  bool _rateEnabled = false;
  bool _customEnabled = false;
  List<_RuntimeOption> _runtimes = const [];
  List<String> _cronIds = const [];
  String _webhookTarget = 'upstream';
  String _cronId = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in [
      _domains,
      _listen,
      _root,
      _runDir,
      _index,
      _accessLog,
      _errorLog,
      _bodySize,
      _upstreams,
      _proxyHeaders,
      _redirects,
      _rewrites,
      _corsOrigins,
      _corsMethods,
      _corsHeaders,
      _hotlinkExtensions,
      _realIpHeader,
      _realIpTrusted,
      _rateRps,
      _rateBurst,
      _rateConnections,
      _custom,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.api.getJson('/api/v1/sites/${widget.siteName}');
      final detail = SiteDetail.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _site = detail.site;
        _apply(detail.site);
        _loading = false;
      });
      if (detail.site.kind == 'webhook') {
        if (detail.webhookTargets.contains('cron')) _loadCronIds();
      } else {
        _loadRuntimes();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  void _apply(Site site) {
    _kind = site.kind;
    _webhookTarget = site.webhook?.target ?? 'upstream';
    _cronId = site.webhook?.cronId ?? '';
    _enabled = site.enabled;
    _ipv6 = site.ipv6;
    _runtimeId = site.runtimeId;
    _domains.text = site.domains.join('\n');
    _listen.text = site.listen.toString();
    _root.text = site.root;
    _runDir.text = site.runDir;
    _index.text = site.index.join(' ');
    _accessLog.text = site.accessLog;
    _errorLog.text = site.errorLog;
    _bodySize.text = site.clientMaxBodySize;
    _upstreams.text = [
      for (final upstream in site.proxy.upstreams)
        site.kind != 'webhook' && upstream.weight > 1
            ? '${upstream.address} ${upstream.weight}'
            : upstream.address,
    ].join('\n');
    _proxyHeaders.text = [
      for (final header in site.proxy.headers)
        '${header.name}: ${header.value}',
    ].join('\n');
    _loadBalance = site.proxy.loadBalance;
    _proxyWebsocket = site.proxy.websocket;
    _proxyPreserveHost = site.proxy.preserveHost;
    _redirects.text = [
      for (final redirect in site.redirects)
        '${redirect.from} -> ${redirect.to} ${redirect.code}',
    ].join('\n');
    _rewrites.text = [
      for (final rewrite in site.rewrites)
        '${rewrite.pattern} ${rewrite.replacement} ${rewrite.flag}',
    ].join('\n');
    _corsEnabled = site.cors.enabled;
    _corsCredentials = site.cors.credentials;
    _corsOrigins.text = site.cors.origins.join('\n');
    _corsMethods.text = site.cors.methods.join('\n');
    _corsHeaders.text = site.cors.headers.join('\n');
    _hotlinkEnabled = site.hotlink.enabled;
    _hotlinkAllowEmpty = site.hotlink.allowEmptyReferer;
    _hotlinkExtensions.text = site.hotlink.extensions.join('\n');
    _realIpEnabled = site.realIp.enabled;
    _realIpHeader.text = site.realIp.header;
    _realIpTrusted.text = site.realIp.trusted.join('\n');
    _rateEnabled = site.rateLimit.enabled;
    _rateRps.text = site.rateLimit.rps.toString();
    _rateBurst.text = site.rateLimit.burst.toString();
    _rateConnections.text = site.rateLimit.connections.toString();
    _tlsEnabled = site.tls.enabled;
    _tlsRedirect = site.tls.redirectHttp;
    _tlsHsts = site.tls.hsts;
    _tlsCertificate = site.tls.certificate;
    _tlsKey = site.tls.key;
    _basicEnabled = site.basicAuth.enabled;
    _basicUsers = [for (final user in site.basicAuth.users) user.username];
    _customEnabled = site.custom.enabled;
    _custom.text = site.custom.content;
  }

  Future<void> _loadRuntimes() async {
    try {
      final json = await widget.api.getJson('/api/v1/runtimes');
      final items =
          ((json as Map<String, dynamic>?)?['environments']
              as List<dynamic>?) ??
          const [];
      if (!mounted) return;
      setState(() {
        _runtimes = [
          for (final item in items.whereType<Map<String, dynamic>>())
            _RuntimeOption(
              id: item['id'] as String? ?? '',
              name: item['name'] as String? ?? '',
              status: item['status'] as String? ?? '',
            ),
        ];
      });
    } catch (_) {
      if (mounted) setState(() => _runtimes = const []);
    }
  }

  Future<void> _loadCronIds() async {
    try {
      final data =
          await widget.api.getJson('/api/v1/cron') as Map<String, dynamic>;
      if (!mounted) return;
      setState(
        () => _cronIds = [
          for (final entry in (data['entries'] as List<dynamic>? ?? const []))
            if (entry is Map<String, dynamic> &&
                entry['id'] is String &&
                (entry['id'] as String).isNotEmpty)
              entry['id'] as String,
        ],
      );
    } catch (_) {
      if (mounted) setState(() => _cronIds = const []);
    }
  }

  bool get _isCron => _isWebhook && _webhookTarget == 'cron';

  bool get _isWebhook => _kind == 'webhook';

  bool get _canRevokeCronWebhook =>
      _site?.kind == 'webhook' && _site?.webhook?.target == 'cron';

  bool get _canManageCronWebhook =>
      _canRevokeCronWebhook &&
      _detail?.webserver == 'nginx' &&
      _detail?.webhookTargets.contains('cron') == true;

  Future<void> _manageCronToken({required bool rotate}) async {
    if (_saving || (rotate ? !_canManageCronWebhook : !_canRevokeCronWebhook)) {
      return;
    }
    final confirmed = await confirmDialog(
      context,
      title: rotate ? '轮换 Webhook 凭据？' : '撤销 Webhook 凭据？',
      message: rotate
          ? '旧 URL 将立即失效；新凭据仅在本次响应中显示，请先准备好安全保存并更新发送方。轮换也会重新启用已撤销的绑定。'
          : '现有 URL 将失效，站点和 Cron 任务不会删除；已经接受的任务不会被终止。之后可通过轮换生成新凭据。',
      confirmLabel: rotate ? '轮换' : '撤销',
      danger: true,
    );
    if (!confirmed ||
        !mounted ||
        (rotate ? !_canManageCronWebhook : !_canRevokeCronWebhook)) {
      return;
    }
    setState(() => _saving = true);
    try {
      final path = '/api/v1/sites/${widget.siteName}/webhook';
      if (rotate) {
        final json = await widget.api.postJson('$path/rotate', null);
        if (!mounted) return;
        final response = json as Map<String, dynamic>? ?? const {};
        if (response['ok'] != true) throw StateError('轮换未成功');
        if (!hasWebhookCredential(response)) {
          _toast('轮换成功，但响应未提供凭据；请再次轮换以取得新 URL。');
        } else {
          await showWebhookCredential(context, response);
        }
      } else {
        final json = await widget.api.deleteJson('$path/token');
        if (!mounted) return;
        if (json is! Map<String, dynamic> || json['ok'] != true) {
          throw StateError('撤销未成功');
        }
        _toast('已请求撤销凭据；详情页无法查询凭据状态');
      }
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _save() async {
    final old = _site;
    if (old == null || _saving) return;
    if (_kind == 'webhook') {
      if (!isWebhookProvider(_detail?.webserver)) {
        _toast('当前 WebServer 不支持 Webhook 站点');
        return;
      }
      if (_detail?.webhookTargets.contains(_webhookTarget) != true) {
        _toast('当前 daemon 不支持该 Webhook 目标');
        return;
      }
      if (_isCron &&
          (!isWebhookTlsPath(_tlsCertificate) ||
              !isWebhookTlsPath(_tlsKey) ||
              _lines(_domains, splitComma: true).isEmpty)) {
        _toast('内部 Cron 需要回调域名以及证书链和私钥的服务器绝对路径');
        return;
      }
      if (_webhookTarget == 'cron' && !_cronIds.contains(_cronId)) {
        _toast('请选择已有的 Cron ID');
        return;
      }
      if (_webhookTarget == 'upstream' && !isWebhookOrigin(_upstreams.text)) {
        _toast(webhookOriginHint);
        return;
      }
    }
    setState(() => _saving = true);
    final tls = SiteTls(
      enabled: _isCron || _tlsEnabled,
      certificate: _tlsCertificate,
      key: _tlsKey,
      acmeEmail: old.tls.acmeEmail,
      redirectHttp: _tlsRedirect,
      hsts: _tlsHsts,
    );
    final rateLimit = SiteRateLimit(
      enabled: _rateEnabled,
      rps: int.tryParse(_rateRps.text.trim()) ?? 10,
      burst: int.tryParse(_rateBurst.text.trim()) ?? 20,
      connections: int.tryParse(_rateConnections.text.trim()) ?? 0,
    );
    final domains = _lines(_domains, splitComma: true);
    final listen = int.tryParse(_listen.text.trim()) ?? 80;
    final nginx = _detail?.webserver == 'nginx';
    final body = _isWebhook
        ? webhookUpdateJson(
            name: widget.siteName,
            enabled: _enabled,
            domains: domains,
            listen: listen,
            origin: _webhookTarget == 'upstream' ? _upstreams.text : '',
            webhook: SiteWebhook(target: _webhookTarget, cronId: _cronId),
            tls: tls,
            ipv6: nginx ? _ipv6 : null,
            rateLimit: nginx ? rateLimit : null,
          )
        : Site(
            name: widget.siteName,
            kind: _kind,
            enabled: _enabled,
            domains: domains,
            listen: listen,
            ipv6: _ipv6,
            root: _root.text.trim(),
            runDir: _runDir.text.trim(),
            index: _words(_index),
            accessLog: _accessLog.text.trim(),
            errorLog: _errorLog.text.trim(),
            clientMaxBodySize: _bodySize.text.trim(),
            runtimeId: _runtimeId,
            tls: tls,
            rateLimit: rateLimit,
            basicAuth: SiteBasicAuth(
              enabled: _basicEnabled,
              users: old.basicAuth.users,
            ),
            cors: SiteCors(
              enabled: _corsEnabled,
              origins: _lines(_corsOrigins, splitComma: true),
              methods: _lines(_corsMethods, splitComma: true),
              headers: _lines(_corsHeaders, splitComma: true),
              credentials: _corsCredentials,
            ),
            hotlink: SiteHotlink(
              enabled: _hotlinkEnabled,
              allowEmptyReferer: _hotlinkAllowEmpty,
              extensions: _lines(_hotlinkExtensions, splitComma: true),
            ),
            redirects: _parseRedirects(),
            rewrites: _parseRewrites(),
            proxy: SiteProxy(
              upstreams: _parseUpstreams(),
              loadBalance: _loadBalance,
              websocket: _proxyWebsocket,
              preserveHost: _proxyPreserveHost,
              headers: _parseHeaders(),
            ),
            realIp: SiteRealIp(
              enabled: _realIpEnabled,
              header: _realIpHeader.text.trim(),
              trusted: _lines(_realIpTrusted, splitComma: true),
            ),
            custom: SiteCustom(enabled: _customEnabled, content: _custom.text),
            createdAt: old.createdAt,
            updatedAt: old.updatedAt,
          ).toJson();
    try {
      if (_isWebhook && _webhookTarget == 'cron') {
        body['proxy'] = {'upstreams': <Map<String, dynamic>>[]};
      }
      final json = await widget.api.putJson(
        '/api/v1/sites/${widget.siteName}',
        body,
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      final output = (map['output'] as String? ?? '').trim();
      _toast(output.isEmpty ? '已保存并重载' : output);
      if (_isWebhook) await showWebhookCredential(context, map);
      await _load();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _uploadCertificate(String kind) async {
    final text = await _promptPem(kind == 'cert' ? '上传证书链' : '上传私钥');
    if (text == null || text.trim().isEmpty) return;
    try {
      final json = await widget.api.uploadBytes(
        '/api/v1/sites/${widget.siteName}/certificate',
        {'kind': kind},
        utf8.encode(text),
      );
      final map = json as Map<String, dynamic>? ?? const {};
      _toast((map['output'] as String? ?? '已上传').trim());
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<String?> _promptPem(String title) async {
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: DialogBody(
          maxWidth: 760,
          maxHeight: 460,
          child: TextField(
            controller: controller,
            maxLines: 14,
            style: monospace.copyWith(fontSize: 11.5),
            decoration: const InputDecoration(
              labelText: 'PEM 内容',
              hintText: '-----BEGIN ...',
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('上传'),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<void> _editBasicUsers() async {
    final controller = TextEditingController(
      text: [for (final name in _basicUsers) '$name:'].join('\n'),
    );
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('密码访问用户'),
        content: DialogBody(
          maxWidth: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '每行一个 username:password；保存后会替换现有用户。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: controller,
                maxLines: 8,
                style: monospace,
                decoration: const InputDecoration(
                  labelText: '用户列表',
                  hintText: 'admin:password',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (submitted != true) {
      controller.dispose();
      return;
    }
    final users = <Map<String, String>>[];
    for (final line in controller.text.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) continue;
      final separator = trimmed.indexOf(':');
      if (separator <= 0) continue;
      users.add({
        'username': trimmed.substring(0, separator),
        'password': trimmed.substring(separator + 1),
      });
    }
    controller.dispose();
    try {
      final json = await widget.api.postJson(
        '/api/v1/sites/${widget.siteName}/basic-auth',
        {'enabled': true, 'users': users},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      _toast((map['output'] as String? ?? '用户已更新').trim());
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _showLogs(String kind) async {
    final api = widget.api;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogPage(
          title: kind == 'error' ? '错误日志' : '访问日志',
          emptyMessage: '暂无日志',
          load: (lines) async {
            final json = await api.getJson(
              '/api/v1/sites/${widget.siteName}/logs',
              query: {'kind': kind, 'lines': '$lines'},
            );
            final map = json as Map<String, dynamic>? ?? const {};
            return LogPageData(
              content: ((map['lines'] as List<dynamic>?) ?? const [])
                  .whereType<String>()
                  .join('\n'),
              path: map['path'] as String?,
            );
          },
        ),
      ),
    );
  }

  void _previewConfig() {
    final config = _detail?.config ?? '';
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('当前生成的配置'),
        content: DialogBody(
          maxWidth: 900,
          maxHeight: 560,
          child: SingleChildScrollView(
            child: SelectableText(
              config.isEmpty ? (_detail?.configError ?? '暂无配置') : config,
              style: monospace.copyWith(fontSize: 11.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: hampanelBackground,
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('站点 · ${widget.siteName}'),
            Text(
              _detail?.webserver.toUpperCase() ?? '',
              style: TextStyle(fontSize: 10.5, color: hampanelMuted),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '当前配置',
            onPressed: _detail == null ? null : _previewConfig,
            icon: const Icon(Icons.code, size: 20),
          ),
          PageRefreshButton(onPressed: _load),
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: FilledButton.icon(
              onPressed: _loading || _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '保存中' : '保存'),
            ),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ErrorBanner(message: _error!, onRetry: _load),
            )
          : _site == null
          ? const SizedBox.shrink()
          : ListView(
              padding: pageContentPadding(
                context,
                top: 12,
              ).copyWith(bottom: 32),
              children: [
                if (!_isWebhook && _detail?.webserver == 'caddy')
                  _section('引擎说明', [
                    Text(
                      'Caddy 模式：限流、防盗链、真实 IP 和独立错误日志暂不支持；这些配置项仅在 Nginx 下生效。',
                      style: Theme.of(context).textTheme.bodyMedium
                          ?.copyWith(color: hampanelMuted),
                    ),
                  ]),
                _section('基本信息', [
                  if (_isWebhook) const Text('站点类型：Webhook') else _kindField(),
                  _gap(),
                  _switch('启用站点', _enabled, (value) {
                    setState(() => _enabled = value);
                  }),
                  if (!_isWebhook || _detail?.webserver == 'nginx')
                    _switch('IPv6 监听', _ipv6, (value) {
                      setState(() => _ipv6 = value);
                    }),
                  if (_kind == 'runtime') ...[
                    _gap(),
                    DropdownButtonFormField<String>(
                      initialValue:
                          _runtimes.any((item) => item.id == _runtimeId)
                          ? _runtimeId
                          : null,
                      decoration: const InputDecoration(labelText: '运行环境'),
                      items: [
                        for (final runtime in _runtimes)
                          DropdownMenuItem(
                            value: runtime.id,
                            child: Text('${runtime.name} · ${runtime.status}'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _runtimeId = value);
                      },
                    ),
                  ],
                  _gap(),
                  _field(_domains, '域名', hint: '每行一个或逗号分隔', maxLines: 2),
                  _gap(),
                  if (!_isCron && (!_isWebhook || !_tlsEnabled))
                    _field(_listen, 'HTTP 监听端口', number: true),
                ]),
                if (!_isWebhook)
                  _section('目录与日志', [
                    _pathField(_root, '站点根目录', hint: '/var/www/example'),
                    _gap(),
                    _pathField(_runDir, '运行目录', hint: '默认与站点根目录相同'),
                    _gap(),
                    _field(_index, '默认文档', hint: 'index.html index.htm'),
                    _gap(),
                    _pathField(
                      _accessLog,
                      '访问日志路径',
                      hint: '留空使用全局日志',
                      allowFiles: true,
                    ),
                    _gap(),
                    _pathField(
                      _errorLog,
                      '错误日志路径',
                      hint: '留空使用全局日志',
                      allowFiles: true,
                    ),
                    _gap(),
                    _field(_bodySize, '请求体大小限制', hint: '如 16m'),
                  ]),
                if (_kind == 'webhook')
                  _section('Webhook', [
                    if (!_detail!.webhookTargets.contains(_webhookTarget))
                      const Text('当前 daemon 不支持此目标；不可保存。'),
                    DropdownButtonFormField<String>(
                      initialValue:
                          _detail!.webhookTargets.contains(_webhookTarget)
                          ? _webhookTarget
                          : null,
                      decoration: const InputDecoration(labelText: '回调目标'),
                      items: [
                        if (_detail!.webhookTargets.contains('upstream'))
                          const DropdownMenuItem(
                            value: 'upstream',
                            child: Text('外部上游'),
                          ),
                        if (_detail!.webhookTargets.contains('cron'))
                          const DropdownMenuItem(
                            value: 'cron',
                            child: Text('内部计划任务'),
                          ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _webhookTarget = value);
                        }
                      },
                    ),
                    if (_webhookTarget == 'cron')
                      DropdownButtonFormField<String>(
                        initialValue: _cronIds.contains(_cronId)
                            ? _cronId
                            : null,
                        decoration: InputDecoration(
                          labelText: '已有 Cron ID',
                          helperText: _cronIds.isEmpty
                              ? '暂无可用任务，请先创建计划任务'
                              : null,
                        ),
                        items: [
                          for (final id in _cronIds)
                            DropdownMenuItem(value: id, child: Text(id)),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _cronId = value);
                        },
                      ),
                    if (_webhookTarget == 'upstream')
                      _field(
                        _upstreams,
                        '固定上游地址',
                        hint: 'https://example.com:8443',
                        mono: true,
                      ),
                    const Text('含 token 的回调 URL 是凭据，请勿公开或写入日志。'),
                    if (_site?.webhook?.target == 'cron') ...[
                      const Text('详情不返回凭据，也无法判断凭据是否已撤销；丢失 URL 时请轮换。'),
                      if (_canRevokeCronWebhook)
                        Wrap(
                          spacing: 12,
                          children: [
                            if (_canManageCronWebhook)
                              OutlinedButton(
                                onPressed: _saving
                                    ? null
                                    : () => _manageCronToken(rotate: true),
                                child: const Text('轮换凭据'),
                              ),
                            OutlinedButton(
                              onPressed: _saving
                                  ? null
                                  : () => _manageCronToken(rotate: false),
                              child: const Text('撤销凭据'),
                            ),
                          ],
                        ),
                    ],
                  ]),
                if (_kind == 'reverse_proxy' ||
                    _kind == 'runtime' ||
                    _kind == 'tcp_proxy' ||
                    _kind == 'udp_proxy')
                  _section('反向代理', [
                    _field(
                      _upstreams,
                      '上游地址',
                      hint: '每行一个，支持 addr weight',
                      maxLines: 4,
                      mono: true,
                    ),
                    _gap(),
                    DropdownButtonFormField<String>(
                      initialValue: _loadBalance,
                      decoration: const InputDecoration(labelText: '负载均衡'),
                      items: const [
                        DropdownMenuItem(
                          value: 'round_robin',
                          child: Text('轮询'),
                        ),
                        DropdownMenuItem(
                          value: 'least_conn',
                          child: Text('最少连接'),
                        ),
                        DropdownMenuItem(
                          value: 'ip_hash',
                          child: Text('IP Hash'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() => _loadBalance = value);
                        }
                      },
                    ),
                    _switch('支持 WebSocket', _proxyWebsocket, (value) {
                      setState(() => _proxyWebsocket = value);
                    }),
                    _switch('保留 Host 头', _proxyPreserveHost, (value) {
                      setState(() => _proxyPreserveHost = value);
                    }),
                    _gap(),
                    _field(
                      _proxyHeaders,
                      '额外请求头',
                      hint: '每行 Name: value',
                      maxLines: 4,
                      mono: true,
                    ),
                  ]),
                if (!_isWebhook)
                  _section('访问控制', [
                    _switch('密码访问', _basicEnabled, (value) {
                      setState(() => _basicEnabled = value);
                    }),
                    if (_basicUsers.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final user in _basicUsers)
                              Chip(label: Text(user)),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: OutlinedButton.icon(
                        onPressed: _editBasicUsers,
                        icon: const Icon(
                          Icons.manage_accounts_outlined,
                          size: 16,
                        ),
                        label: const Text('编辑用户'),
                      ),
                    ),
                    const Divider(height: 24),
                    _switch('CORS', _corsEnabled, (value) {
                      setState(() => _corsEnabled = value);
                    }),
                    if (_corsEnabled) ...[
                      _gap(),
                      _field(
                        _corsOrigins,
                        '允许来源',
                        hint: '每行一个，* 表示全部',
                        maxLines: 3,
                      ),
                      _gap(),
                      _field(_corsMethods, '允许方法', hint: 'GET, POST'),
                      _gap(),
                      _field(_corsHeaders, '允许请求头', hint: 'Content-Type'),
                      _switch('允许凭据', _corsCredentials, (value) {
                        setState(() => _corsCredentials = value);
                      }),
                    ],
                    const Divider(height: 24),
                    _switch('真实 IP 解析', _realIpEnabled, (value) {
                      setState(() => _realIpEnabled = value);
                    }),
                    if (_realIpEnabled) ...[
                      _gap(),
                      _field(_realIpHeader, '真实 IP 头', hint: 'X-Forwarded-For'),
                      _gap(),
                      _field(
                        _realIpTrusted,
                        '可信代理 CIDR',
                        hint: '每行一个，如 10.0.0.0/8',
                        maxLines: 3,
                        mono: true,
                      ),
                    ],
                  ]),
                _section('HTTPS 证书', [
                  if (_isCron)
                    CronTlsFields(
                      certificate: _tlsCertificate,
                      privateKeyPath: _tlsKey,
                      sites: widget.sites,
                      onChanged: (cert, key) => setState(() {
                        _tlsCertificate = cert;
                        _tlsKey = key;
                      }),
                    )
                  else
                    _switch('启用 HTTPS', _tlsEnabled, (value) {
                      setState(() => _tlsEnabled = value);
                    }),
                  if (!_isCron &&
                      (!_isWebhook || _detail?.webserver == 'nginx'))
                    _switch('HTTP 自动跳转 HTTPS', _tlsRedirect, (value) {
                      setState(() => _tlsRedirect = value);
                    }),
                  _switch('HSTS', _tlsHsts, (value) {
                    setState(() => _tlsHsts = value);
                  }),
                  _gap(),
                  if (!_isCron)
                    Text(
                      _tlsCertificate.isEmpty
                          ? '证书：未上传'
                          : '证书：$_tlsCertificate',
                      style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                    ),
                  if (!_isCron)
                    Text(
                      _tlsKey.isEmpty ? '私钥：未上传' : '私钥：$_tlsKey',
                      style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                    ),
                  _gap(),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => _uploadCertificate('cert'),
                        icon: const Icon(Icons.upload_file_outlined, size: 16),
                        label: const Text('上传证书链'),
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _uploadCertificate('key'),
                        icon: const Icon(Icons.key_outlined, size: 16),
                        label: const Text('上传私钥'),
                      ),
                    ],
                  ),
                ]),
                if (!_isWebhook)
                  _section('重定向与伪静态', [
                    _field(
                      _redirects,
                      '重定向',
                      hint: '每行 /old -> /new 301',
                      maxLines: 4,
                      mono: true,
                    ),
                    _gap(),
                    _field(
                      _rewrites,
                      '伪静态',
                      hint: '每行 pattern replacement [last]',
                      maxLines: 4,
                      mono: true,
                    ),
                  ]),
                if (!_isWebhook || _detail?.webserver == 'nginx')
                  _section(_isWebhook ? '限流' : '限流与防盗链', [
                    _switch('启用限流', _rateEnabled, (value) {
                      setState(() => _rateEnabled = value);
                    }),
                    if (_rateEnabled) ...[
                      _gap(),
                      _field(_rateRps, '每秒请求数', number: true),
                      _gap(),
                      _field(_rateBurst, '突发请求数', number: true),
                      _gap(),
                      _field(_rateConnections, '并发连接数（0 不限制）', number: true),
                    ],
                    if (!_isWebhook) const Divider(height: 24),
                    if (!_isWebhook)
                      _switch('启用防盗链', _hotlinkEnabled, (value) {
                        setState(() => _hotlinkEnabled = value);
                      }),
                    if (!_isWebhook && _hotlinkEnabled) ...[
                      _switch('允许空 Referer', _hotlinkAllowEmpty, (value) {
                        setState(() => _hotlinkAllowEmpty = value);
                      }),
                      _gap(),
                      _field(
                        _hotlinkExtensions,
                        '受保护扩展名',
                        hint: 'png, jpg, gif',
                        maxLines: 2,
                      ),
                    ],
                  ]),
                if (!_isWebhook)
                  _section('高级', [
                    _switch('使用自定义配置', _customEnabled, (value) {
                      setState(() {
                        _customEnabled = value;
                        if (value && _custom.text.trim().isEmpty) {
                          _custom.text = _detail?.config ?? '';
                        }
                      });
                    }),
                    if (_customEnabled) ...[
                      const SizedBox(height: 8),
                      Text(
                        '启用后，面板直接使用下面的配置，不再生成上面的字段。保存时仍会执行 WebServer 校验。',
                        style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                      ),
                      const SizedBox(height: 8),
                      TextField(
                        controller: _custom,
                        minLines: 12,
                        maxLines: 24,
                        style: monospace.copyWith(fontSize: 11.5),
                        decoration: const InputDecoration(
                          labelText: '自定义配置',
                          alignLabelWithHint: true,
                        ),
                      ),
                    ],
                  ]),
                if (!_isWebhook)
                  _section('日志', [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton.icon(
                          onPressed: () => _showLogs('access'),
                          icon: const Icon(Icons.list_alt_outlined, size: 16),
                          label: const Text('查看访问日志'),
                        ),
                        OutlinedButton.icon(
                          onPressed: () => _showLogs('error'),
                          icon: const Icon(Icons.error_outline, size: 16),
                          label: const Text('查看错误日志'),
                        ),
                      ],
                    ),
                  ]),
              ],
            ),
    );
  }

  List<SiteUpstream> _parseUpstreams() {
    final result = <SiteUpstream>[];
    for (final line in _linesInput(_upstreams)) {
      final fields = line.split(RegExp(r'\s+'));
      if (fields.isEmpty) continue;
      result.add(
        SiteUpstream(
          address: fields.first,
          weight: fields.length > 1 ? int.tryParse(fields[1]) ?? 1 : 1,
        ),
      );
    }
    return result;
  }

  List<SiteProxyHeader> _parseHeaders() {
    final result = <SiteProxyHeader>[];
    for (final line in _linesInput(_proxyHeaders)) {
      final separator = line.indexOf(':');
      if (separator <= 0) continue;
      result.add(
        SiteProxyHeader(
          name: line.substring(0, separator).trim(),
          value: line.substring(separator + 1).trim(),
        ),
      );
    }
    return result;
  }

  List<SiteRedirect> _parseRedirects() {
    final result = <SiteRedirect>[];
    final pattern = RegExp(r'^(\S+)\s*->\s*(\S+)(?:\s+(\d{3}))?$');
    for (final line in _linesInput(_redirects)) {
      final match = pattern.firstMatch(line);
      if (match == null) continue;
      result.add(
        SiteRedirect(
          from: match.group(1) ?? '',
          to: match.group(2) ?? '',
          code: int.tryParse(match.group(3) ?? '') ?? 301,
        ),
      );
    }
    return result;
  }

  List<SiteRewrite> _parseRewrites() {
    final result = <SiteRewrite>[];
    for (final line in _linesInput(_rewrites)) {
      final fields = line.split(RegExp(r'\s+'));
      if (fields.length < 2) continue;
      result.add(
        SiteRewrite(
          pattern: fields[0],
          replacement: fields[1],
          flag: fields.length > 2 ? fields[2] : 'last',
        ),
      );
    }
    return result;
  }

  Widget _kindField() {
    return DropdownButtonFormField<String>(
      initialValue: _kind,
      decoration: const InputDecoration(labelText: '站点类型'),
      items: const [
        DropdownMenuItem(value: 'static', child: Text('静态网站')),
        DropdownMenuItem(value: 'reverse_proxy', child: Text('反向代理')),
        DropdownMenuItem(value: 'runtime', child: Text('运行环境')),
        DropdownMenuItem(value: 'subsite', child: Text('子网站')),
        DropdownMenuItem(value: 'tcp_proxy', child: Text('TCP 代理')),
        DropdownMenuItem(value: 'udp_proxy', child: Text('UDP 代理')),
      ],
      onChanged: (value) {
        if (value != null) setState(() => _kind = value);
      },
    );
  }

  Widget _section(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: PanelCard(
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  Widget _pathField(
    TextEditingController controller,
    String label, {
    String? hint,
    bool allowFiles = false,
  }) {
    return RemotePathField(
      api: widget.api,
      controller: controller,
      label: label,
      hintText: hint,
      allowFiles: allowFiles,
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    bool number = false,
    bool mono = false,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      keyboardType: number ? TextInputType.number : TextInputType.text,
      minLines: 1,
      maxLines: maxLines,
      style: mono ? monospace : null,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }

  Widget _switch(String title, bool value, ValueChanged<bool> onChanged) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 12.5)),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _gap() => const SizedBox(height: 10);
}

class _RuntimeOption {
  const _RuntimeOption({
    required this.id,
    required this.name,
    required this.status,
  });

  final String id;
  final String name;
  final String status;
}

List<String> _lines(
  TextEditingController controller, {
  bool splitComma = false,
}) {
  final pattern = splitComma ? RegExp(r'[\n,]+') : RegExp(r'\n');
  return controller.text
      .split(pattern)
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
}

List<String> _words(TextEditingController controller) {
  return controller.text
      .split(RegExp(r'[\s,]+'))
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
}

List<String> _linesInput(TextEditingController controller) {
  return controller.text
      .split('\n')
      .map((value) => value.trim())
      .where((value) => value.isNotEmpty)
      .toList();
}
