import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/site.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

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

  Future<void> _create() async {
    final nameController = TextEditingController();
    final domainsController = TextEditingController();
    final rootController = TextEditingController(text: '/var/www');
    final portController = TextEditingController(text: '80');

    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新建站点'),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
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
              TextField(
                controller: rootController,
                decoration: const InputDecoration(labelText: '站点根目录'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: portController,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '监听端口'),
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
    );

    if (submitted != true) {
      nameController.dispose();
      domainsController.dispose();
      rootController.dispose();
      portController.dispose();
      return;
    }

    final domains = domainsController.text
        .split(RegExp(r'[,\s]+'))
        .where((value) => value.trim().isNotEmpty)
        .toList();
    final port = int.tryParse(portController.text.trim()) ?? 80;

    try {
      final json = await _api.postJson('/api/v1/sites', {
        'name': nameController.text.trim(),
        'domains': domains,
        'root': rootController.text.trim(),
        'port': port,
      });
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
      portController.dispose();
    }
  }

  Future<void> _toggle(SiteInfo site, bool enabled) async {
    try {
      await _api.postJson('/api/v1/sites/${site.name}/toggle', {
        'enabled': enabled,
      });
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _delete(SiteInfo site) async {
    final ok = await confirmDialog(
      context,
      title: '删除站点 ${site.name}?',
      message: '将删除 Nginx 站点配置文件并重载服务。',
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

  Future<void> _reload() async {
    try {
      final json = await _api.postJson(
        '/api/v1/sites/reload',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      _toast(
        (map['ok'] as bool? ?? false)
            ? 'Nginx 已重载'
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
    return Column(
      children: [
        PageHeader(
          title: '网站',
          subtitle: list == null ? '正在读取 Nginx 站点' : '配置目录 ${list.directory}',
          actions: [
            OutlinedButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建站点'),
            ),
            const SizedBox(width: 8),
            OutlinedButton.icon(
              onPressed: _reload,
              icon: const Icon(Icons.sync, size: 16),
              label: const Text('重载 Nginx'),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
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
                  message: '未检测到 Nginx，或当前平台不提供站点管理功能。',
                  action: OutlinedButton(
                    onPressed: _load,
                    child: const Text('重新检测'),
                  ),
                )
              : list.sites.isEmpty
              ? EmptyState(
                  icon: Icons.add_to_queue_outlined,
                  title: '还没有站点',
                  message: '创建一个 Nginx 站点，面板会校验配置后自动重载。',
                  action: FilledButton(
                    onPressed: _create,
                    child: const Text('新建站点'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  itemCount: list.sites.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final site = list.sites[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.language,
                              size: 20,
                              color: site.enabled
                                  ? hampanelAccent
                                  : hampanelMuted,
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    site.name,
                                    style: const TextStyle(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    site.domains.join(', '),
                                    style: TextStyle(
                                      fontSize: 11.5,
                                      color: hampanelMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Expanded(
                              flex: 3,
                              child: Text(
                                site.root,
                                overflow: TextOverflow.ellipsis,
                                style: monospace.copyWith(fontSize: 11.5),
                              ),
                            ),
                            SizedBox(
                              width: 90,
                              child: Text(
                                site.listen.isEmpty ? '-' : site.listen,
                                style: monospace.copyWith(fontSize: 11.5),
                              ),
                            ),
                            StatusPill(
                              text: site.enabled ? '已启用' : '已停用',
                              good: site.enabled,
                            ),
                            const SizedBox(width: 10),
                            Switch(
                              value: site.enabled,
                              onChanged: (value) => _toggle(site, value),
                            ),
                            IconButton(
                              tooltip: '删除站点',
                              onPressed: () => _delete(site),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ],
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
