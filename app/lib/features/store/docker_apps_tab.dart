import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/store_app.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/log_page.dart';
import '../../ui/widgets.dart';
import 'deploy_dialog.dart';

class DockerAppsTab extends StatefulWidget {
  const DockerAppsTab({super.key});

  @override
  State<DockerAppsTab> createState() => _DockerAppsTabState();
}

class _DockerAppsTabState extends State<DockerAppsTab> {
  List<StoreApp> _apps = const [];
  bool _loading = true;
  String? _error;
  String? _category;
  String _query = '';
  final _search = TextEditingController();

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/store/apps');
      final map = json as Map<String, dynamic>;
      final apps = ((map['apps'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(StoreApp.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _apps = apps;
        if (!apps.any((app) => app.category == _category)) _category = null;
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

  Future<void> _deploy(StoreApp app) async {
    final values = await showDeployDialog(context, app);
    if (values == null) return;
    if (!mounted) return;
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'store.deploy',
        title: '部署 ${app.name}',
        params: {'slug': app.slug, 'params': values},
      );
      if (!mounted) return;
      _toast('已提交任务：${task.title}');
      unawaited(
        center.waitFor(task.id).then((summary) async {
          if (!mounted) return;
          try {
            final detail = await _api.getJson('/api/v1/tasks/${task.id}');
            final map = detail as Map<String, dynamic>? ?? const {};
            final output = map['output'] as String? ?? '';
            final raw = map['result'] as String? ?? '';
            List<dynamic> params = const [];
            if (raw.isNotEmpty) {
              final parsed = jsonDecode(raw);
              if (parsed is Map<String, dynamic>) {
                params = (parsed['params'] as List<dynamic>?) ?? const [];
              }
            }
            if (!mounted) return;
            if (summary?.status == 'succeeded') {
              await showDeployedDialog(context, app.name, params, output);
            } else {
              await showOutputDialog(context, '部署失败', output);
            }
          } catch (_) {}
          if (mounted) await _load();
        }),
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _action(StoreApp app, String action) async {
    if (action == 'deploy') {
      await _deploy(app);
      return;
    }
    if (action == 'remove' || action == 'remove-volumes') {
      final removeVolumes = action == 'remove-volumes';
      final ok = await confirmDialog(
        context,
        title: '卸载 ${app.name}?',
        message: removeVolumes
            ? '容器、网络和命名数据卷都会被删除，数据无法恢复。'
            : '容器与网络会被删除，命名数据卷会保留。',
        confirmLabel: '卸载',
        danger: true,
      );
      if (!ok) return;
      if (!mounted) return;
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'store.app',
        title: '卸载 ${app.name}',
        params: {
          'slug': app.slug,
          'action': 'remove',
          'volumes': removeVolumes,
        },
      );
      if (!mounted) return;
      _toast('已提交任务：${task.title}');
      unawaited(
        center.waitFor(task.id).then((_) {
          if (mounted) _load();
        }),
      );
      return;
    }

    if (action == 'upgrade-nginx') {
      final ok = await confirmDialog(
        context,
        title: '升级旧版 Nginx 部署？',
        message: '仅支持未修改的旧版商店配置。将重新创建容器，保留当前端口和 HTML 数据卷，服务可能短暂中断。',
        confirmLabel: '升级',
      );
      if (!ok || !mounted) return;
    }

    if (action == 'logs') {
      final api = _api;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => LogPage(
            title: '${app.name} 日志',
            load: (lines) async {
              final json = await api.getJson(
                '/api/v1/store/apps/${app.slug}/logs',
                query: {'lines': '$lines'},
              );
              final map = json as Map<String, dynamic>? ?? const {};
              return LogPageData(content: map['output'] as String? ?? '');
            },
          ),
        ),
      );
      return;
    }

    final center = PanelScope.of(context).tasks;
    final task = await center.submit(
      'store.app',
      title: '${app.name}: $action',
      params: {'slug': app.slug, 'action': action},
    );
    if (!mounted) return;
    _toast('已提交任务：${task.title}');
    unawaited(
      center.waitFor(task.id).then((_) {
        if (mounted) _load();
      }),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  IconData _icon(String name) {
    return switch (name) {
      'web' => Icons.public,
      'database' => Icons.storage_outlined,
      'storage' => Icons.cloud_outlined,
      'git' => Icons.account_tree_outlined,
      'monitor' => Icons.monitor_heart_outlined,
      'code' => Icons.code,
      'tools' => Icons.build_outlined,
      'bell' => Icons.notifications_active_outlined,
      'cert' => Icons.verified_user_outlined,
      _ => Icons.apps,
    };
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return LoadingView();
    if (_error != null) {
      return SingleChildScrollView(
        child: ErrorBanner(message: _error!, onRetry: _load),
      );
    }
    if (_apps.isEmpty) {
      return EmptyState(
        icon: Icons.storefront_outlined,
        title: '应用目录为空',
        message: '在 daemon/src/store/catalog 中添加应用后重新构建。',
      );
    }

    final categories = _apps
        .map((app) => app.category)
        .where((value) => value.isNotEmpty)
        .toSet()
        .toList();
    final query = _query.trim().toLowerCase();
    final visibleApps = _apps.where((app) {
      if (_category != null && app.category != _category) return false;
      return query.isEmpty ||
          '${app.name} ${app.slug} ${app.description} ${app.category}'
              .toLowerCase()
              .contains(query);
    }).toList();

    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 360).floor().clamp(1, 3);
          return CustomScrollView(
            physics: const AlwaysScrollableScrollPhysics(),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: pageContentPadding(context, top: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: _search,
                        decoration: const InputDecoration(
                          labelText: '搜索应用',
                          prefixIcon: Icon(Icons.search),
                        ),
                        onChanged: (value) => setState(() => _query = value),
                      ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerRight,
                        child: OutlinedButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh, size: 16),
                          label: const Text('刷新状态'),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          ChoiceChip(
                            label: const Text('全部'),
                            selected: _category == null,
                            onSelected: (_) => setState(() => _category = null),
                          ),
                          for (final category in categories)
                            ChoiceChip(
                              label: Text(category),
                              selected: _category == category,
                              onSelected: (_) =>
                                  setState(() => _category = category),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              if (visibleApps.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: TextButton(
                      onPressed: () => setState(() {
                        _category = null;
                        _query = '';
                        _search.clear();
                      }),
                      child: const Text('没有匹配的应用，清除筛选'),
                    ),
                  ),
                ),
              SliverPadding(
                padding: pageContentPadding(context, top: 12),
                sliver: SliverGrid.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: columns,
                    mainAxisExtent: 226,
                    crossAxisSpacing: 12,
                    mainAxisSpacing: 12,
                  ),
                  itemCount: visibleApps.length,
                  itemBuilder: (context, index) {
                    final app = visibleApps[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: hampanelAccent.withValues(
                                      alpha: 0.10,
                                    ),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Icon(
                                    _icon(app.icon),
                                    size: 20,
                                    color: hampanelAccent,
                                  ),
                                ),
                                const SizedBox(width: 11),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        app.name,
                                        style: const TextStyle(
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                      Text(
                                        app.category,
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: hampanelMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                StatusPill(
                                  text: !app.installed
                                      ? '未部署'
                                      : app.running == null
                                      ? '状态未知'
                                      : app.running == true
                                      ? '运行中'
                                      : '已停止',
                                  good: app.running == true,
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Expanded(
                              child: Text(
                                app.description,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: hampanelMuted,
                                  height: 1.5,
                                ),
                              ),
                            ),
                            Row(
                              children: [
                                if (!app.installed)
                                  FilledButton.icon(
                                    onPressed: () => _deploy(app),
                                    icon: const Icon(
                                      Icons.rocket_launch_outlined,
                                      size: 15,
                                    ),
                                    label: const Text('部署'),
                                  )
                                else if (app.running == true)
                                  OutlinedButton(
                                    onPressed: () => _action(app, 'stop'),
                                    child: const Text('停止'),
                                  )
                                else if (app.running == false)
                                  OutlinedButton(
                                    onPressed: () => _action(app, 'start'),
                                    child: const Text('启动'),
                                  ),
                                const Spacer(),
                                PopupMenuButton<String>(
                                  tooltip: '更多',
                                  icon: const Icon(Icons.more_horiz, size: 19),
                                  onSelected: (value) => _action(app, value),
                                  itemBuilder: (context) => [
                                    if (app.installed)
                                      const PopupMenuItem(
                                        value: 'logs',
                                        child: Text('查看日志'),
                                      ),
                                    if (app.installed &&
                                        app.slug == 'nginx' &&
                                        app.legacyUpgradeAvailable)
                                      const PopupMenuItem(
                                        value: 'upgrade-nginx',
                                        child: Text('升级旧版部署（保留端口）'),
                                      ),
                                    if (app.installed)
                                      const PopupMenuItem(
                                        value: 'deploy',
                                        child: Text('使用新参数重新部署'),
                                      ),
                                    const PopupMenuItem(
                                      value: 'remove',
                                      child: Text('卸载（保留数据）'),
                                    ),
                                    const PopupMenuItem(
                                      value: 'remove-volumes',
                                      child: Text('卸载并删除数据'),
                                    ),
                                  ],
                                ),
                              ],
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
        },
      ),
    );
  }
}
