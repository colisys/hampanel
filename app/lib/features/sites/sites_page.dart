import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/site.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/log_viewer.dart';
import '../../ui/widgets.dart';
import 'site_detail_page.dart';

class SitesPage extends StatefulWidget {
  const SitesPage({super.key});

  @override
  State<SitesPage> createState() => _SitesPageState();
}

class _SitesPageState extends State<SitesPage> {
  SiteList? _list;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => PanelScope.of(context).api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/sites');
      if (!mounted) return;
      setState(() {
        _list = SiteList.fromJson(json as Map<String, dynamic>);
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

  Future<void> _open(Site site) async {
    final api = _api;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SiteDetailPage(api: api, siteName: site.name),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _create() async {
    final api = _api;
    final runtimes = await _loadRuntimes(api);
    if (!mounted) return;
    final nameController = TextEditingController();
    final domainsController = TextEditingController();
    final rootController = TextEditingController(text: '/var/www');
    final targetController = TextEditingController(text: '127.0.0.1:3000');
    final portController = TextEditingController(text: '80');
    var kind = 'static';
    var runtimeId = runtimes.isNotEmpty ? runtimes.first.id : '';

    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          scrollable: true,
          title: const Text('新建站点'),
          content: DialogBody(
            maxWidth: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: kind,
                  decoration: const InputDecoration(labelText: '站点类型'),
                  items: const [
                    DropdownMenuItem(value: 'static', child: Text('静态网站')),
                    DropdownMenuItem(
                      value: 'reverse_proxy',
                      child: Text('反向代理'),
                    ),
                    DropdownMenuItem(value: 'tcp_proxy', child: Text('TCP 代理')),
                    DropdownMenuItem(value: 'udp_proxy', child: Text('UDP 代理')),
                    DropdownMenuItem(value: 'runtime', child: Text('运行环境')),
                    DropdownMenuItem(value: 'subsite', child: Text('子网站')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => kind = value ?? 'static'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(labelText: '站点标识（英文 slug）'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: domainsController,
                  decoration: const InputDecoration(
                    labelText: '域名',
                    hintText: 'example.com, www.example.com',
                  ),
                ),
                const SizedBox(height: 12),
                if (kind == 'static' || kind == 'subsite')
                  TextField(
                    controller: rootController,
                    decoration: const InputDecoration(labelText: '站点根目录'),
                  ),
                if (kind == 'reverse_proxy' || kind == 'tcp_proxy' || kind == 'udp_proxy')
                  TextField(
                    controller: targetController,
                    decoration: const InputDecoration(
                      labelText: '上游地址',
                      hintText: '127.0.0.1:3000',
                    ),
                  ),
                if (kind == 'runtime')
                  DropdownButtonFormField<String>(
                    initialValue: runtimes.any((item) => item.id == runtimeId)
                        ? runtimeId
                        : null,
                    decoration: const InputDecoration(labelText: '运行环境'),
                    items: [
                      for (final runtime in runtimes)
                        DropdownMenuItem(
                          value: runtime.id,
                          child: Text(
                            '${runtime.name} · ${runtime.status}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) =>
                        setDialogState(() => runtimeId = value ?? ''),
                  ),
                const SizedBox(height: 12),
                TextField(
                  controller: portController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'HTTP 监听端口'),
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
              child: const Text('创建'),
            ),
          ],
        ),
      ),
    );

    if (submitted != true) {
      nameController.dispose();
      domainsController.dispose();
      rootController.dispose();
      targetController.dispose();
      portController.dispose();
      return;
    }

    final domains = domainsController.text
        .split(RegExp(r'[,\s]+'))
        .where((value) => value.trim().isNotEmpty)
        .toList();
    final port = int.tryParse(portController.text.trim()) ?? 80;
    final body = <String, dynamic>{
      'name': nameController.text.trim(),
      'kind': kind,
      'domains': domains,
      'listen': port,
    };
    if (kind == 'static' || kind == 'subsite') {
      body['root'] = rootController.text.trim();
    }
    if (kind == 'reverse_proxy' || kind == 'tcp_proxy' || kind == 'udp_proxy') {
      body['proxy_target'] = targetController.text.trim();
    }
    if (kind == 'runtime') {
      body['runtime_id'] = runtimeId;
    }

    try {
      final json = await api.postJson('/api/v1/sites', body);
      final map = json as Map<String, dynamic>? ?? const {};
      final output = (map['output'] as String? ?? '').trim();
      if (output.isNotEmpty) _toast(output);
      await _load();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      nameController.dispose();
      domainsController.dispose();
      rootController.dispose();
      targetController.dispose();
      portController.dispose();
    }
  }

  Future<List<_RuntimeOption>> _loadRuntimes(ApiClient api) async {
    try {
      final json = await api.getJson('/api/v1/runtimes');
      final items =
          ((json as Map<String, dynamic>?)?['environments'] as List<dynamic>?) ??
          const [];
      return [
        for (final item in items.whereType<Map<String, dynamic>>())
          _RuntimeOption(
            id: item['id'] as String? ?? '',
            name: item['name'] as String? ?? '',
            status: item['status'] as String? ?? '',
            port: (item['port'] as num?)?.toInt(),
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> _toggle(Site site, bool enabled) async {
    try {
      await _api.postJson('/api/v1/sites/${site.name}/toggle', {
        'enabled': enabled,
      });
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _delete(Site site) async {
    final ok = await confirmDialog(
      context,
      title: '删除站点 ${site.name}?',
      message: '将删除面板托管的站点配置并重载 WebServer。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.deleteJson('/api/v1/sites/${site.name}');
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _logs(Site site) async {
    final api = _api;
    try {
      final json = await api.getJson(
        '/api/v1/sites/${site.name}/logs',
        query: const {'kind': 'access', 'lines': '500'},
      );
      if (!mounted) return;
      final map = json as Map<String, dynamic>? ?? const {};
      final lines = ((map['lines'] as List<dynamic>?) ?? const [])
          .whereType<String>()
          .join('\n');
      await showLogViewerDialog(
        context,
        title: '访问日志 · ${site.name}',
        content: lines,
        path: map['path'] as String?,
        emptyMessage: '暂无日志',
      );
    } catch (error) {
      if (mounted) _toast(describeError(error));
    }
  }

  Future<void> _reload() async {
    try {
      final json = await _api.postJson(
        '/api/v1/sites/reload',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      _toast(
        (map['ok'] as bool? ?? false)
            ? 'WebServer 已重载'
            : (map['output'] as String? ?? '重载失败'),
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final list = _list;
    final available = list?.available == true && list?.supported == true;
    return Column(
      children: [
        PageHeader(
          title: '网站',
          subtitle: list == null
              ? '正在读取站点'
              : list.webserver.isEmpty
              ? '未检测到可用的 WebServer'
              : '${list.webserver.toUpperCase()} · ${list.directory}',
          actions: available
              ? [
                  OutlinedButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建站点'),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _reload,
                    icon: const Icon(Icons.sync, size: 16),
                    label: const Text('重载'),
                  ),
                  const SizedBox(width: 8),
                  PageRefreshButton(onPressed: _load, refreshing: _loading),
                ]
              : [
                  PageRefreshButton(onPressed: _load, refreshing: _loading),
                ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : list == null || !list.available
              ? EmptyState(
                  icon: Icons.public_off_outlined,
                  title: '当前环境无法管理站点',
                  message: '未检测到可用的 WebServer，或当前平台不提供站点管理功能。',
                  action: OutlinedButton(
                    onPressed: _load,
                    child: const Text('重新检测'),
                  ),
                )
              : !list.supported
              ? EmptyState(
                  icon: Icons.construction_outlined,
                  title: '站点配置暂未开放',
                  message: list.message.isEmpty
                      ? '当前 WebServer 暂不支持站点配置。'
                      : list.message,
                )
              : list.sites.isEmpty
              ? EmptyState(
                  icon: Icons.add_to_queue_outlined,
                  title: '还没有站点',
                  message: '创建站点后，面板会生成配置、校验并自动重载 WebServer。',
                  action: FilledButton(
                    onPressed: _create,
                    child: const Text('新建站点'),
                  ),
                )
              : ListView.separated(
                  padding: pageContentPadding(context, top: 4),
                  itemCount: list.sites.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final site = list.sites[index];
                    return Card(
                      child: InkWell(
                        onTap: () => _open(site),
                        borderRadius: BorderRadius.circular(3),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(
                                    Icons.language,
                                    size: 20,
                                    color: site.enabled
                                        ? hampanelAccent
                                        : hampanelMuted,
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Text(
                                      site.name,
                                      style: const TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                  StatusPill(
                                    text: site.enabled ? '已启用' : '已停用',
                                    good: site.enabled,
                                  ),
                                  PopupMenuButton<String>(
                                    icon: const Icon(Icons.more_horiz, size: 18),
                                    onSelected: (value) {
                                      switch (value) {
                                        case 'edit':
                                          _open(site);
                                        case 'logs':
                                          _logs(site);
                                        case 'toggle':
                                          _toggle(site, !site.enabled);
                                        case 'delete':
                                          _delete(site);
                                      }
                                    },
                                    itemBuilder: (context) => [
                                      const PopupMenuItem(
                                        value: 'edit',
                                        child: Text('编辑配置'),
                                      ),
                                      const PopupMenuItem(
                                        value: 'logs',
                                        child: Text('访问日志'),
                                      ),
                                      PopupMenuItem(
                                        value: 'toggle',
                                        child: Text(
                                          site.enabled ? '停用站点' : '启用站点',
                                        ),
                                      ),
                                      const PopupMenuItem(
                                        value: 'delete',
                                        child: Text('删除站点'),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Wrap(
                                spacing: 16,
                                runSpacing: 6,
                                children: [
                                  _Info(
                                    label: '类型',
                                    value: _kindLabel(site.kind),
                                  ),
                                  _Info(
                                    label: '域名',
                                    value: site.domains.isEmpty
                                        ? '—'
                                        : site.domains.join(', '),
                                  ),
                                  _Info(
                                    label: '目标',
                                    value: site.summaryTarget.isEmpty
                                        ? '—'
                                        : site.summaryTarget,
                                    mono: true,
                                  ),
                                  _Info(
                                    label: '端口',
                                    value: site.listen.toString(),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RuntimeOption {
  const _RuntimeOption({
    required this.id,
    required this.name,
    required this.status,
    required this.port,
  });

  final String id;
  final String name;
  final String status;
  final int? port;
}

class _Info extends StatelessWidget {
  const _Info({required this.label, required this.value, this.mono = false});

  final String label;
  final String value;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$label ',
          style: TextStyle(fontSize: 10.5, color: hampanelMuted),
        ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: mono
                ? monospace.copyWith(fontSize: 11)
                : const TextStyle(fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

String _kindLabel(String kind) => switch (kind) {
  'reverse_proxy' => '反向代理',
  'runtime' => '运行环境',
  'subsite' => '子网站',
  'tcp_proxy' => 'TCP 代理',
  'udp_proxy' => 'UDP 代理',
  _ => '静态网站',
};
