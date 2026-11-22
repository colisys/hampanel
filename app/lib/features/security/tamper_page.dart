import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/security.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/remote_picker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// 文件防篡改. The host capability is probed first: when the required component is
/// absent this page explains what is missing instead of showing empty controls.
class TamperPage extends StatefulWidget {
  const TamperPage({super.key});

  @override
  State<TamperPage> createState() => _TamperPageState();
}

class _TamperPageState extends State<TamperPage> {
  SecurityCapabilities? _capabilities;
  Map<String, dynamic>? _status;
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
      final caps = await _api.getJson('/api/v1/security/capabilities');
      final status = await _api.getJson('/api/v1/security/tamper');
      if (!mounted) return;
      setState(() {
        _capabilities = SecurityCapabilities.fromJson(
          caps as Map<String, dynamic>? ?? const {},
        );
        _status = status as Map<String, dynamic>? ?? const {};
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

  bool get _ready {
    final caps = _capabilities;
    if (caps == null) return false;
    return switch ('chattr') {
      'qemu' => caps.qemu,
      'chattr' => caps.chattr,
      'selinux' => caps.selinux,
      _ => false,
    };
  }

  Future<void> _add() async {
    final picked = await showRemotePicker(
      context,
      source: HostDirectorySource(_api),
      allowFiles: true,
      confirmLabel: '保护该路径',
    );
    if (picked == null || !mounted) return;
    await _apply('/api/v1/security/tamper', picked, '已保护 $picked');
  }

  Future<void> _remove(String path) async {
    final ok = await confirmDialog(
      context,
      title: '解除保护?',
      message: '会清除 $path 的不可变属性，之后可以再次修改。',
      confirmLabel: '解除',
      danger: true,
    );
    if (!ok) return;
    await _apply('/api/v1/security/tamper/remove', path, '已解除 $path');
  }

  Future<void> _apply(String endpoint, String path, String message) async {
    try {
      final json = await _api.postJson(endpoint, {'path': path});
      final map = json as Map<String, dynamic>? ?? const {};
      if (map['ok'] != true) {
        _toast((map['output'] as String? ?? '操作失败').trim());
        return;
      }
      _toast(message);
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppSnackBar(context, SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final entries = ((status?['entries'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final ready = _ready;
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件防篡改'),
        actions: [
          PageRefreshButton(onPressed: _load, refreshing: _loading),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: ActionDock(
        actions: [
          ActionDockItem(
            icon: Icons.add_moderator_outlined,
            label: '保护路径',
            onPressed: ready && !_loading && _error == null ? _add : null,
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? Padding(
              padding: pageContentPadding(context),
              child: ErrorBanner(message: _error!, onRetry: _load),
            )
          : ListView(
              padding: pageContentPadding(context),
              children: [
                PanelCard(
                  title: '本机状态',
                  trailing: StatusPill(text: ready ? '可用' : '不可用', good: ready),
                  child: Text(
                    status?['message'] as String? ??
                        (ready
                            ? 'chattr 可用：受保护路径即使 root 也无法改写；目录会递归保护，重启后自动恢复。'
                            : '缺少 chattr/lsattr，无法进行不可变保护。'),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '受保护的路径',
                  trailing: Text(
                    '${entries.length} 个',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  child: entries.isEmpty
                      ? Text(
                          ready ? '尚未保护任何路径。' : '当前主机不具备 chattr，入口不会展示无效开关。',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: hampanelMuted,
                          ),
                        )
                      : Column(
                          children: [
                            for (final entry in entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Icon(
                                      entry['immutable'] == true
                                          ? Icons.lock
                                          : Icons.lock_open,
                                      size: 16,
                                      color: entry['immutable'] == true
                                          ? hampanelAccent
                                          : hampanelMuted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry['path'] as String? ?? '',
                                            style: monospace.copyWith(
                                              fontSize: 11.5,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            '${entry['attributes'] ?? ''}'
                                            '${entry['present'] == false ? ' · 路径已不存在' : ''}',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: hampanelMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '解除保护',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => _remove(
                                        entry['path'] as String? ?? '',
                                      ),
                                      icon: const Icon(
                                        Icons.lock_open,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
