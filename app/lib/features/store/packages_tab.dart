import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/package_tool.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'deploy_dialog.dart';

class PackagesTab extends StatefulWidget {
  const PackagesTab({super.key});

  @override
  State<PackagesTab> createState() => _PackagesTabState();
}

class _PackagesTabState extends State<PackagesTab> {
  PackageStatus? _status;
  bool _loading = true;
  String? _error;
  String? _busyId;

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
      final json = await _api.getJson('/api/v1/store/packages');
      if (!mounted) return;
      setState(() {
        _status = PackageStatus.fromJson(json as Map<String, dynamic>);
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

  Future<void> _install(PackageTool tool) async {
    setState(() => _busyId = tool.id);
    try {
      final json = await _api.postJson(
        '/api/v1/store/packages/${tool.id}/install',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(context, '安装失败', map['output'] as String? ?? '');
      } else {
        _toast('${tool.name} 已安装');
        await _load();
      }
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _refresh() async {
    try {
      final json = await _api.postJson(
        '/api/v1/store/packages/refresh',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (map['ok'] == false) {
        if (!mounted) return;
        await showOutputDialog(
          context,
          '刷新软件源失败',
          map['output'] as String? ?? '',
        );
      } else {
        _toast('软件源索引已刷新');
      }
      await _load();
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
    if (_loading) return const LoadingView();
    if (_error != null) {
      return SingleChildScrollView(
        child: ErrorBanner(message: _error!, onRetry: _load),
      );
    }
    final status = _status;
    if (status == null || !status.available) {
      return EmptyState(
        icon: Icons.inventory_2_outlined,
        title: '当前平台不支持包管理器',
        message:
            '已检测到的管理器: ${status?.manager ?? 'none'}。'
            'Linux 支持 apt/dnf/yum/zypper/pacman/apk；Windows 暂未启用此功能。',
        action: OutlinedButton(onPressed: _load, child: const Text('重新检测')),
      );
    }

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 8, 24, 10),
          child: Row(
            children: [
              StatusPill(text: status.manager, good: true),
              const SizedBox(width: 10),
              Text(
                '${status.tools.length} 个精选工具',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
              const Spacer(),
              OutlinedButton.icon(
                onPressed: _refresh,
                icon: const Icon(Icons.sync, size: 16),
                label: const Text('刷新软件源'),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            itemCount: status.tools.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final tool = status.tools[index];
              final busy = _busyId == tool.id;
              return Card(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.terminal, size: 18, color: hampanelMuted),
                      const SizedBox(width: 14),
                      Expanded(
                        flex: 3,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tool.name,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              tool.description,
                              style: TextStyle(
                                fontSize: 11.5,
                                color: hampanelMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Text(
                          tool.binary,
                          style: monospace.copyWith(fontSize: 11.5),
                        ),
                      ),
                      StatusPill(
                        text: tool.installed ? '已安装' : '未安装',
                        good: tool.installed,
                      ),
                      const SizedBox(width: 10),
                      SizedBox(
                        width: 108,
                        child: FilledButton(
                          onPressed: tool.installed || busy
                              ? null
                              : () => _install(tool),
                          child: busy
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Text(tool.installed ? '已就绪' : '安装'),
                        ),
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
