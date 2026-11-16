import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/waf_status.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';

class WafPage extends StatefulWidget {
  const WafPage({super.key});

  @override
  State<WafPage> createState() => _WafPageState();
}

class _WafPageState extends State<WafPage> {
  WafStatus? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  final _listenHost = TextEditingController();
  final _listenPort = TextEditingController();
  final _upstreamHost = TextEditingController();
  final _upstreamPort = TextEditingController();
  final _riskPort = TextEditingController(text: '18092');
  final _typesafeEndpoint = TextEditingController(
    text: 'https://api.typesafe.ai/v1/systemone',
  );
  final _typesafeModel = TextEditingController(text: 'jev-latest');
  final _typesafeThreshold = TextEditingController(text: '0.85');
  final _typesafeTimeout = TextEditingController(text: '800');
  final _typesafeKey = TextEditingController();
  final _tlsEmail = TextEditingController();
  String _mode = 'detect';
  final List<WafRoute> _routes = [];
  bool _tlsEnabled = false;
  String _tlsMode = 'internal';
  bool _riskEnabled = true;
  bool _typesafeEnabled = false;
  bool _failOpen = true;
  Set<String> _geoipSelected = {};
  Set<String> _geositeSelected = {};
  GeoCatalog? _catalog;
  bool _catalogLoading = false;

  bool get _keyConfigured => _status?.typesafeKeyConfigured ?? false;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _listenHost.dispose();
    _listenPort.dispose();
    _upstreamHost.dispose();
    _upstreamPort.dispose();
    _riskPort.dispose();
    _typesafeEndpoint.dispose();
    _typesafeModel.dispose();
    _typesafeThreshold.dispose();
    _typesafeTimeout.dispose();
    _typesafeKey.dispose();
    _tlsEmail.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/waf');
      final status = WafStatus.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _status = status;
        _mode = status.mode;
        _listenHost.text = status.listenHost;
        _listenPort.text = status.listenPort > 0
            ? '${status.listenPort}'
            : '8088';
        _upstreamHost.text = status.upstreamHost;
        _upstreamPort.text = status.upstreamPort > 0
            ? '${status.upstreamPort}'
            : '80';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  Future<void> _install() async {
    final ok = await confirmDialog(
      context,
      title: '构建 Caddy + Coraza？',
      message:
          '将在服务器上通过 xcaddy 编译带 Coraza 模块的 Caddy，'
          '并内置 OWASP CRS。需要 Go 工具链和网络，可能需要数分钟。',
      confirmLabel: '开始构建',
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      final json = await _api.postJson(
        '/api/v1/waf/install',
        const {},
        timeout: const Duration(minutes: 20),
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      await showOutputDialog(
        context,
        map['ok'] == true ? 'WAF 构建完成' : 'WAF 构建失败',
        map['output'] as String? ?? '',
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(error))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final listenPort = int.tryParse(_listenPort.text.trim());
    final upstreamPort = int.tryParse(_upstreamPort.text.trim());
    if (listenPort == null || upstreamPort == null) {
      _toast('端口必须是数字');
      return;
    }
    if (_mode == 'enforce') {
      final ok = await confirmDialog(
        context,
        title: '切换到 enforce 模式？',
        message:
            'enforce 会直接阻断命中 CRS 规则的请求。'
            '建议先在 detect 模式观察日志，确认没有误拦截后再切换。',
        confirmLabel: '启用阻断',
        danger: true,
      );
      if (!ok) return;
    }
    setState(() => _busy = true);
    try {
      final riskPort = int.tryParse(_riskPort.text.trim());
      final threshold = double.tryParse(_typesafeThreshold.text.trim());
      final timeout = int.tryParse(_typesafeTimeout.text.trim());
      if (riskPort == null || threshold == null || timeout == null) {
        _toast('risk 端口/阈值/超时格式不正确');
        setState(() => _busy = false);
        return;
      }
      final json = await _api.postJson('/api/v1/waf/config', {
        'mode': _mode,
        'listen_host': _listenHost.text.trim(),
        'listen_port': listenPort,
        'upstream_host': _upstreamHost.text.trim(),
        'upstream_port': upstreamPort,
        'risk_enabled': _riskEnabled,
        'risk_port': riskPort,
        'typesafe_enabled': _typesafeEnabled,
        'typesafe_endpoint': _typesafeEndpoint.text.trim(),
        'typesafe_model': _typesafeModel.text.trim(),
        'typesafe_threshold': threshold,
        'typesafe_timeout_ms': timeout,
        'typesafe_fail_open': _failOpen,
        'geoip_rules': [
          for (final tag in _geoipSelected) {'tag': tag, 'action': 'deny'},
        ],
        'geosite_rules': [
          for (final tag in _geositeSelected) {'tag': tag, 'action': 'deny'},
        ],
        'routes': [for (final route in _routes) route.toJson()],
        'tls_enabled': _tlsEnabled,
        'tls_mode': _tlsMode,
        'tls_email': _tlsEmail.text.trim(),
      });
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      await showOutputDialog(
        context,
        map['ok'] == true ? 'WAF 配置已保存' : 'WAF 配置失败',
        map['output'] as String? ?? '',
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _startStop(bool start) async {
    setState(() => _busy = true);
    try {
      final json = await _api.postJson(
        start ? '/api/v1/waf/start' : '/api/v1/waf/stop',
        const {},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(context, '操作失败', map['output'] as String? ?? '');
      } else {
        _toast(map['output'] as String? ?? (start ? '已启动' : '已停止'));
      }
      await _load();
    } catch (error) {
      if (!mounted) return;
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showLogs([String source = 'access']) async {
    try {
      final json = await _api.getJson(
        '/api/v1/waf/logs',
        query: {'lines': '300', 'source': source},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      await showOutputDialog(
        context,
        source == 'risk'
            ? 'WAF 风险日志'
            : source == 'audit'
            ? 'Coraza 规则审计'
            : 'WAF 访问日志',
        map['content'] as String? ?? '',
      );
    } catch (error) {
      if (!mounted) return;
      _toast(describeError(error));
    }
  }

  Future<void> _saveKey() async {
    final key = _typesafeKey.text.trim();
    if (key.length < 8) {
      _toast('API Key 至少 8 个字符');
      return;
    }
    setState(() => _busy = true);
    try {
      final json = await _api.postJson('/api/v1/waf/typesafe/key', {
        'api_key': key,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      _typesafeKey.clear();
      await showOutputDialog(
        context,
        map['ok'] == true ? '密钥已加密保存' : '密钥保存失败',
        map['output'] as String? ?? '',
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clearKey() async {
    final ok = await confirmDialog(
      context,
      title: '删除 TypeSafe 密钥？',
      message: '删除后 risk gateway 将无法调用 TypeSafe 进行风险复检。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      final json = await _api.deleteJson('/api/v1/waf/typesafe/key');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      _toast(map['output'] as String? ?? '已删除');
      await _load();
    } catch (error) {
      if (!mounted) return;
      _toast(describeError(error));
    }
  }

  Future<void> _loadCatalog({bool refresh = false}) async {
    setState(() => _catalogLoading = true);
    try {
      final json = await _api.getJson(
        '/api/v1/waf/geo/catalog',
        query: refresh ? const {'refresh': '1'} : null,
      );
      final catalog = GeoCatalog.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _catalog = catalog;
        _catalogLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _catalogLoading = false);
      _toast(describeError(error));
    }
  }

  Future<void> _selectCountries() async {
    final catalog = _catalog;
    if (catalog == null) return;
    final selected = Set<String>.from(_geoipSelected);
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('选择 GeoIP 国家/地区（拒绝）'),
          content: DialogBody(
            maxWidth: 520,
            maxHeight: 460,
            child: ListView(
              children: [
                for (final country in catalog.countries)
                  CheckboxListTile(
                    dense: true,
                    value: selected.contains(country.code),
                    title: Text('${country.name}  (${country.code})'),
                    onChanged: (value) => setDialogState(() {
                      if (value == true) {
                        selected.add(country.code);
                      } else {
                        selected.remove(country.code);
                      }
                    }),
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
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
    if (saved == true && mounted) {
      setState(() => _geoipSelected = selected);
    }
  }

  Future<void> _selectGeoSites() async {
    final catalog = _catalog;
    if (catalog == null) return;
    final selected = Set<String>.from(_geositeSelected);
    var search = '';
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) {
          final filtered = catalog.geosite
              .where(
                (item) =>
                    search.isEmpty ||
                    item.name.toLowerCase().contains(search.toLowerCase()) ||
                    item.id.toLowerCase().contains(search.toLowerCase()),
              )
              .toList();
          return AlertDialog(
            title: const Text('选择 GeoSite 分类（拒绝）'),
            content: DialogBody(
              maxWidth: 620,
              maxHeight: 520,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      labelText: '搜索名称或标签',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (value) =>
                        setDialogState(() => search = value.trim()),
                  ),
                  const SizedBox(height: 6),
                  Expanded(
                    child: ListView(
                      children: [
                        for (final item in filtered)
                          CheckboxListTile(
                            dense: true,
                            value: selected.contains(item.id),
                            title: Text('${item.name}  (${item.id})'),
                            subtitle: Text(
                              item.category,
                              style: const TextStyle(fontSize: 10.5),
                            ),
                            onChanged: (value) => setDialogState(() {
                              if (value == true) {
                                selected.add(item.id);
                              } else {
                                selected.remove(item.id);
                              }
                            }),
                          ),
                      ],
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
                child: const Text('确定'),
              ),
            ],
          );
        },
      ),
    );
    if (saved == true && mounted) {
      setState(() => _geositeSelected = selected);
    }
  }

  Future<void> _editRoute([WafRoute? existing]) async {
    final name = TextEditingController(text: existing?.name ?? '');
    final hosts = TextEditingController(text: existing?.hosts.join(',') ?? '');
    final upstreamHost = TextEditingController(
      text: existing?.upstreamHost ?? _upstreamHost.text,
    );
    final upstreamPort = TextEditingController(
      text:
          '${existing?.upstreamPort ?? int.tryParse(_upstreamPort.text) ?? 80}',
    );
    var routeMode = existing?.mode ?? 'inherit';
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? '新增站点策略' : '编辑站点策略'),
          content: DialogBody(
            maxWidth: 620,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                FormRow(
                  flex: const [3, 2],
                  children: [
                    TextField(
                      controller: name,
                      decoration: const InputDecoration(labelText: '策略名称'),
                    ),
                    DropdownButtonFormField<String>(
                      initialValue: routeMode,
                      decoration: const InputDecoration(labelText: 'WAF 模式'),
                      items: const [
                        DropdownMenuItem(value: 'inherit', child: Text('继承全局')),
                        DropdownMenuItem(value: 'off', child: Text('关闭')),
                        DropdownMenuItem(value: 'detect', child: Text('检测')),
                        DropdownMenuItem(value: 'enforce', child: Text('拦截')),
                      ],
                      onChanged: (value) =>
                          setDialogState(() => routeMode = value ?? 'inherit'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: hosts,
                  decoration: const InputDecoration(
                    labelText: '域名（逗号分隔，支持 *.example.com）',
                  ),
                ),
                const SizedBox(height: 8),
                FormRow(
                  flex: const [3, 2],
                  children: [
                    TextField(
                      controller: upstreamHost,
                      decoration: const InputDecoration(labelText: '上游主机'),
                    ),
                    TextField(
                      controller: upstreamPort,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: '上游端口'),
                    ),
                  ],
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
      ),
    );
    if (saved == true && mounted) {
      final port = int.tryParse(upstreamPort.text.trim());
      final hostList = hosts.text
          .split(',')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
      if (name.text.trim().isEmpty ||
          hostList.isEmpty ||
          upstreamHost.text.trim().isEmpty ||
          port == null) {
        _toast('请填写名称、域名和上游地址');
      } else {
        final route = WafRoute(
          name: name.text.trim(),
          hosts: hostList,
          upstreamHost: upstreamHost.text.trim(),
          upstreamPort: port,
          mode: routeMode,
        );
        setState(() {
          if (existing == null) {
            _routes.add(route);
          } else {
            final index = _routes.indexOf(existing);
            if (index >= 0) _routes[index] = route;
          }
        });
      }
    }
    name.dispose();
    hosts.dispose();
    upstreamHost.dispose();
    upstreamPort.dispose();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: 'WAF',
          subtitle: 'Caddy + Coraza + OWASP CRS 独立边缘，对任意 Web 引擎统一防护',
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _loading || _busy ? null : _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        Expanded(
          child: _loading
              ? const LoadingView()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  children: [
                    if (_error != null) ...[
                      ErrorBanner(message: _error!, onRetry: _load),
                      const SizedBox(height: 12),
                    ],
                    if (_status == null) const SizedBox.shrink(),
                    if (_status != null) ..._content(_status!),
                  ],
                ),
        ),
      ],
    );
  }

  List<Widget> _content(WafStatus status) {
    return [
      PanelCard(
        title: 'WAF 边缘状态',
        trailing: Wrap(
          spacing: 8,
          children: [
            StatusPill(
              text: status.running ? '运行中' : '已停止',
              good: status.running,
            ),
            StatusPill(
              text: status.mode == 'enforce'
                  ? 'enforce'
                  : status.mode == 'off'
                  ? 'off'
                  : 'detect',
              good: status.mode != 'off',
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _kv('版本', status.version.isEmpty ? '未安装' : status.version),
            _kv('监听', '${status.listenHost}:${status.listenPort}'),
            _kv('上游', '${status.upstreamHost}:${status.upstreamPort}'),
            _kv('CRS', status.crs.isEmpty ? '-' : status.crs),
            _kv(
              'Risk gateway',
              '${status.riskRunning ? '运行中' : '未运行'} · 127.0.0.1:${status.riskPort}',
            ),
            _kv('TypeSafe Key', status.typesafeKeyConfigured ? '已加密保存' : '未配置'),
            _kv(
              'Geo 规则',
              '国家 ${status.geoipRules.length} · 站点 ${status.geositeRules.length}',
            ),
            _kv('二进制', status.binary),
            if (status.message.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                status.message,
                style: TextStyle(
                  fontSize: 11.5,
                  color: hampanelMuted,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (!status.installed)
                  FilledButton.icon(
                    onPressed: _busy || !status.goAvailable ? null : _install,
                    icon: const Icon(Icons.build_outlined, size: 16),
                    label: Text(_busy ? '构建中…' : '构建 Caddy+Coraza'),
                  )
                else ...[
                  if (status.running)
                    OutlinedButton.icon(
                      onPressed: _busy ? null : () => _startStop(false),
                      icon: const Icon(Icons.stop, size: 16),
                      label: const Text('停止'),
                    )
                  else
                    FilledButton.icon(
                      onPressed: _busy || status.mode == 'off'
                          ? null
                          : () => _startStop(true),
                      icon: const Icon(Icons.play_arrow, size: 16),
                      label: const Text('启动'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _showLogs('access'),
                    icon: const Icon(Icons.article_outlined, size: 16),
                    label: const Text('访问日志'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _showLogs('risk'),
                    icon: const Icon(Icons.security_outlined, size: 16),
                    label: const Text('风控日志'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => _showLogs('audit'),
                    icon: const Icon(Icons.rule, size: 16),
                    label: const Text('规则审计'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _install,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新构建'),
                  ),
                ],
              ],
            ),
            if (!status.installed && !status.goAvailable) ...[
              const SizedBox(height: 8),
              Text(
                '服务器没有 Go 工具链。请先安装 Go，或把带 Coraza 的 caddy 二进制放到上述路径。',
                style: TextStyle(fontSize: 11, color: hampanelDanger),
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 14),
      PanelCard(
        title: '边缘配置',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<String>(
              key: ValueKey(_mode),
              initialValue: _mode,
              decoration: const InputDecoration(labelText: '模式'),
              items: const [
                DropdownMenuItem(value: 'off', child: Text('off（停止 WAF）')),
                DropdownMenuItem(
                  value: 'detect',
                  child: Text('detect（记录但不阻断）'),
                ),
                DropdownMenuItem(
                  value: 'enforce',
                  child: Text('enforce（阻断命中规则）'),
                ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      if (value != null) setState(() => _mode = value);
                    },
            ),
            const SizedBox(height: 10),
            FormRow(
              flex: const [3, 2],
              children: [
                TextField(
                  controller: _listenHost,
                  decoration: const InputDecoration(
                    labelText: '监听地址',
                    hintText: '0.0.0.0',
                  ),
                ),
                TextField(
                  controller: _listenPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '监听端口'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FormRow(
              flex: const [3, 2],
              children: [
                TextField(
                  controller: _upstreamHost,
                  decoration: const InputDecoration(
                    labelText: '上游 Web 引擎地址',
                    hintText: '127.0.0.1',
                  ),
                ),
                TextField(
                  controller: _upstreamPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '上游端口'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            FormRow(
              flex: const [3, 1],
              children: [
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('启用 risk gateway'),
                  subtitle: const Text('TypeSafe 与 Geo 规则在独立 Go 网关上执行'),
                  value: _riskEnabled,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _riskEnabled = value),
                ),
                TextField(
                  controller: _riskPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Risk 端口'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '上游应指向 Nginx / OpenResty / Caddy 的回环监听端口。'
              '当前边缘为 HTTP；TLS/域名接入和按站点策略将在后续补齐。'
              '切换 enforce 前请先观察 detect 日志，避免误拦截。',
              style: TextStyle(fontSize: 11, color: hampanelMuted, height: 1.5),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _busy || !status.installed ? null : _save,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('校验并保存配置'),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      PanelCard(
        title: '站点策略与 TLS',
        trailing: StatusPill(
          text: _tlsEnabled
              ? 'TLS ${_tlsMode == 'internal' ? 'internal' : 'ACME'}'
              : 'HTTP',
          good: _tlsEnabled,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用 TLS 终止'),
              subtitle: const Text('internal 用于测试/内网；ACME 需要公网域名与 80/443'),
              value: _tlsEnabled,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _tlsEnabled = value),
            ),
            if (_tlsEnabled)
              LayoutBuilder(
                builder: (context, constraints) {
                  final mode = DropdownButtonFormField<String>(
                    key: ValueKey(_tlsMode),
                    initialValue: _tlsMode,
                    decoration: const InputDecoration(labelText: '证书模式'),
                    items: const [
                      DropdownMenuItem(
                        value: 'internal',
                        child: Text('internal'),
                      ),
                      DropdownMenuItem(value: 'acme', child: Text('ACME')),
                    ],
                    onChanged: (value) =>
                        setState(() => _tlsMode = value ?? 'internal'),
                  );
                  if (_tlsMode != 'acme') {
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: SizedBox(width: 180, child: mode),
                    );
                  }
                  final email = TextField(
                    controller: _tlsEmail,
                    decoration: const InputDecoration(labelText: 'ACME 邮箱'),
                  );
                  if (constraints.maxWidth < 600) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [mode, const SizedBox(height: 10), email],
                    );
                  }
                  return Row(
                    children: [
                      SizedBox(width: 180, child: mode),
                      const SizedBox(width: 10),
                      Expanded(child: email),
                    ],
                  );
                },
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '按 Host 匹配站点策略；每个策略独立设置 WAF 模式与上游。'
                    '未匹配域名使用上方全局模式与上游。',
                    style: TextStyle(
                      fontSize: 11,
                      color: hampanelMuted,
                      height: 1.5,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _editRoute(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('新增策略'),
                ),
              ],
            ),
            if (_routes.isEmpty)
              Padding(
                padding: EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  '尚未配置站点策略',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
              )
            else
              for (final route in _routes)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text('${route.name} · ${route.hosts.join(', ')}'),
                  subtitle: Text(
                    '${route.upstreamHost}:${route.upstreamPort} · 模式 ${route.mode}',
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        onPressed: _busy ? null : () => _editRoute(route),
                        icon: const Icon(Icons.edit_outlined, size: 18),
                      ),
                      IconButton(
                        onPressed: _busy
                            ? null
                            : () => setState(() => _routes.remove(route)),
                        icon: const Icon(Icons.delete_outline, size: 18),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      PanelCard(
        title: 'TypeSafe 风险复检',
        trailing: StatusPill(
          text: _keyConfigured ? '密钥已加密' : '未配置密钥',
          good: _keyConfigured,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('启用 TypeSafe'),
              subtitle: const Text('对受限大小的请求体调用 /v1/systemone noul 判定'),
              value: _typesafeEnabled,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _typesafeEnabled = value),
            ),
            TextField(
              controller: _typesafeEndpoint,
              decoration: const InputDecoration(labelText: 'TypeSafe Endpoint'),
            ),
            const SizedBox(height: 8),
            FormRow(
              flex: const [3, 1, 1],
              children: [
                TextField(
                  controller: _typesafeModel,
                  decoration: const InputDecoration(labelText: '模型'),
                ),
                TextField(
                  controller: _typesafeThreshold,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '阈值'),
                ),
                TextField(
                  controller: _typesafeTimeout,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '超时 ms'),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('失败时放行（fail-open）'),
              subtitle: const Text('关闭后，TypeSafe 超时/错误会按 enforce 规则阻断'),
              value: _failOpen,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _failOpen = value),
            ),
            FieldWithActions(
              field: TextField(
                controller: _typesafeKey,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'API Key（仅写入，不会回显）',
                  hintText: _keyConfigured ? '已保存，可留空' : 'sk-...',
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: _busy ? null : _saveKey,
                  child: const Text('加密保存'),
                ),
                OutlinedButton(
                  onPressed: _busy || !_keyConfigured ? null : _clearKey,
                  child: const Text('删除'),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '密钥通过 systemd-creds 加密保存，risk gateway 启动时解密到内存；'
              '面板 API 不返回明文。',
              style: TextStyle(fontSize: 11, color: hampanelMuted, height: 1.5),
            ),
          ],
        ),
      ),
      const SizedBox(height: 14),
      PanelCard(
        title: 'Geo 选择器（拒绝）',
        trailing: _catalogLoading
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : StatusPill(
                text: _catalog == null
                    ? '未加载目录'
                    : '${_catalog!.countries.length} 国家 / ${_catalog!.geosite.length} 分类',
                good: _catalog != null,
              ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '数据来自 Geo-Aggregator：GeoIP 使用 source2 国家 CIDR，'
              'GeoSite 使用 source1 域名分类。保存配置时会下载所选列表并重启 WAF。',
              style: TextStyle(fontSize: 11, color: hampanelMuted, height: 1.5),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _catalogLoading ? null : () => _loadCatalog(),
                  icon: const Icon(Icons.download, size: 16),
                  label: Text(_catalog == null ? '加载目录' : '刷新目录'),
                ),
                OutlinedButton.icon(
                  onPressed: _catalog == null || _busy
                      ? null
                      : _selectCountries,
                  icon: const Icon(Icons.public, size: 16),
                  label: Text('国家/地区 (${_geoipSelected.length})'),
                ),
                OutlinedButton.icon(
                  onPressed: _catalog == null || _busy ? null : _selectGeoSites,
                  icon: const Icon(Icons.language, size: 16),
                  label: Text('GeoSite 分类 (${_geositeSelected.length})'),
                ),
              ],
            ),
            if (_geoipSelected.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _geoipSelected.take(12))
                    Chip(
                      label: Text(tag),
                      onDeleted: () =>
                          setState(() => _geoipSelected.remove(tag)),
                    ),
                  if (_geoipSelected.length > 12)
                    Chip(label: Text('+${_geoipSelected.length - 12}')),
                ],
              ),
            ],
            if (_geositeSelected.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final tag in _geositeSelected.take(12))
                    Chip(
                      label: Text(tag),
                      onDeleted: () =>
                          setState(() => _geositeSelected.remove(tag)),
                    ),
                  if (_geositeSelected.length > 12)
                    Chip(label: Text('+${_geositeSelected.length - 12}')),
                ],
              ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 14),
      PanelCard(
        title: '防护说明',
        child: Text(
          '边缘使用 Caddy + Coraza + 内嵌 OWASP CRS，不依赖 Nginx/OpenResty 的 Lua。'
          '所有请求先经过 WAF 再转发到上游引擎；源站必须只监听回环或限制直连，'
          '否则攻击者可以绕过 WAF。\n\n'
          '日志路径：${status.logPath}\n'
          '配置文件：${status.configPath}',
          style: TextStyle(fontSize: 12, color: hampanelMuted, height: 1.6),
        ),
      ),
    ];
  }

  Widget _kv(String key, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 90,
            child: Text(
              key,
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value.isEmpty ? '-' : value,
              style: monospace.copyWith(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }
}
