import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// SELinux policy control.
///
/// The host is probed first: a machine running AppArmor has no SELinux
/// filesystem, so the page explains that instead of showing switches which
/// could never take effect.
class SelinuxPage extends StatefulWidget {
  const SelinuxPage({super.key});

  @override
  State<SelinuxPage> createState() => _SelinuxPageState();
}

class _SelinuxPageState extends State<SelinuxPage> {
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _busy = false;
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
      final json = await _api.getJson('/api/v1/security/selinux');
      if (!mounted) return;
      setState(() {
        _status = json as Map<String, dynamic>? ?? const {};
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

  Future<void> _setMode(String mode) async {
    if (mode == 'disabled') {
      final ok = await confirmDialog(
        context,
        title: '禁用 SELinux？',
        message:
            '将写入 /etc/selinux/config，重启主机后才生效。'
            '禁用后访问控制不再强制，请确认你知道这样做的后果。',
        confirmLabel: '写入配置',
        danger: true,
      );
      if (!ok) return;
    }
    await _post('/api/v1/security/selinux/mode', {'mode': mode}, mode: mode);
  }

  Future<void> _toggleBoolean(String name, bool enabled) async {
    await _post('/api/v1/security/selinux/boolean', {
      'name': name,
      'enabled': enabled,
    });
  }

  Future<void> _post(
    String path,
    Map<String, Object?> body, {
    String? mode,
  }) async {
    setState(() => _busy = true);
    try {
      final json = await _api.postJson(path, body);
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      final reboot = map['reboot_required'] == true;
      final ok = map['ok'] != false;
      showAppSnackBar(
        context,
        SnackBar(
          content: Text(
            reboot
                ? '${map['output'] ?? '已写入配置'}\n需要重启主机后生效。'
                : ok
                ? (mode != null ? '已切换为 $mode' : '已更新')
                : (map['output'] as String? ?? '操作失败'),
          ),
        ),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text(describeError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status ?? const <String, dynamic>{};
    final present = status['present'] == true;
    final tooling = status['tooling'] == true;
    final enforcing = status['enforcing'] as bool?;
    final configured = status['configured'] as String? ?? '';
    final policy = status['policy'] as String? ?? '';
    final booleans = ((status['booleans'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('SELinux'),
        actions: [
          PageRefreshButton(onPressed: _load, refreshing: _loading),
          const SizedBox(width: 8),
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
                  trailing: StatusPill(
                    text: !present
                        ? '未启用'
                        : (enforcing == true ? 'enforcing' : 'permissive'),
                    good: !present ? false : enforcing == true,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status['message'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _row('SELinux 文件系统', present ? '存在' : '不存在'),
                      _row('当前模式', enforcing == null
                          ? '—'
                          : (enforcing ? 'enforcing' : 'permissive')),
                      _row('开机配置', configured.isEmpty ? '—' : configured),
                      _row('策略类型', policy.isEmpty ? '—' : policy),
                      _row('管理工具', tooling ? '已安装' : '未安装'),
                    ],
                  ),
                ),
                if (present) ...[
                  const SizedBox(height: 12),
                  PanelCard(
                    title: '运行模式',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'enforcing / permissive 立即生效；disabled 只写入配置，'
                          '需要重启主机。',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: hampanelMuted,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            for (final mode in const [
                              'enforcing',
                              'permissive',
                              'disabled',
                            ])
                              OutlinedButton(
                                onPressed: _busy || !tooling
                                    ? null
                                    : () => _setMode(mode),
                                child: Text(mode),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (booleans.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    PanelCard(
                      title: '布尔开关',
                      trailing: Text(
                        '${booleans.length} 项',
                        style: TextStyle(fontSize: 11, color: hampanelMuted),
                      ),
                      child: Column(
                        children: [
                          for (final entry in booleans)
                            SwitchListTile(
                              contentPadding: EdgeInsets.zero,
                              dense: true,
                              title: Text(
                                entry['name'] as String? ?? '',
                                style: monospace.copyWith(fontSize: 11.5),
                              ),
                              value: entry['enabled'] == true,
                              onChanged: _busy || !tooling
                                  ? null
                                  : (value) => _toggleBoolean(
                                      entry['name'] as String? ?? '',
                                      value,
                                    ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ],
              ],
            ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
