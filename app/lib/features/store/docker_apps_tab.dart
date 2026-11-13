import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/store_app.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
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
    try {
      final json = await _api.postJson(
        '/api/v1/store/apps/${app.slug}/deploy',
        {'params': values},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final output = map['output'] as String? ?? '';
      if (!mounted) return;
      if (map['ok'] != true) {
        await showOutputDialog(context, '部署失败', output);
      } else {
        await showDeployedDialog(
          context,
          app.name,
          (map['params'] as List<dynamic>?) ?? const [],
          output,
        );
      }
    } catch (error) {
      _toast(describeError(error));
    }
    await _load();
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
      await _runAction(
        () => _api.deleteJson(
          '/api/v1/store/apps/${app.slug}',
          query: removeVolumes ? {'volumes': 'true'} : null,
        ),
        successMessage: '${app.name} 已卸载',
      );
      await _load();
      return;
    }

    if (action == 'logs') {
      try {
        final json = await _api.getJson(
          '/api/v1/store/apps/${app.slug}/logs',
          query: {'lines': '300'},
        );
        final map = json as Map<String, dynamic>;
        if (!mounted) return;
        await showOutputDialog(
          context,
          '${app.name} 日志',
          map['output'] as String? ?? '',
        );
      } catch (error) {
        _toast(describeError(error));
      }
      return;
    }

    await _runAction(
      () => _api.postJson('/api/v1/store/apps/${app.slug}/$action', const {}),
      successMessage: '${app.name}: $action 完成',
    );
    await _load();
  }

  Future<void> _runAction(
    Future<dynamic> Function() operation, {
    required String successMessage,
  }) async {
    try {
      final json = await operation();
      final map = json as Map<String, dynamic>? ?? const {};
      final output = (map['output'] as String? ?? '').trim();
      if (map['ok'] == false) {
        if (!mounted) return;
        await showOutputDialog(
          context,
          '操作失败',
          output.isEmpty ? '未知错误' : output,
        );
        return;
      }
      _toast(successMessage);
    } catch (error) {
      _toast(describeError(error));
    }
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

    return RefreshIndicator(
      onRefresh: _load,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final columns = (constraints.maxWidth / 360).floor().clamp(1, 3);
          return GridView.builder(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: columns,
              mainAxisExtent: 226,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: _apps.length,
            itemBuilder: (context, index) {
              final app = _apps[index];
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
                              color: hampanelAccent.withValues(alpha: 0.10),
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
                              crossAxisAlignment: CrossAxisAlignment.start,
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
                            text: app.installed ? '已部署' : '未部署',
                            good: app.installed,
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
                          else ...[
                            OutlinedButton(
                              onPressed: () => _action(app, 'start'),
                              child: const Text('启动'),
                            ),
                            const SizedBox(width: 6),
                            OutlinedButton(
                              onPressed: () => _action(app, 'stop'),
                              child: const Text('停止'),
                            ),
                          ],
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
          );
        },
      ),
    );
  }
}
