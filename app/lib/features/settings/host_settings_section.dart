import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// 主机级系统设置：交换分区、时间同步、启动项与 hosts。
/// 需要 root 权限，daemon 侧全部通过受控的系统命令执行。
class HostSettingsSection extends StatefulWidget {
  const HostSettingsSection({super.key});

  @override
  State<HostSettingsSection> createState() => _HostSettingsSectionState();
}

class _HostSettingsSectionState extends State<HostSettingsSection> {
  final _swapMb = TextEditingController(text: '2048');
  final _swapDevice = TextEditingController();
  final _hosts = TextEditingController();
  Map<String, dynamic>? _status;
  String? _error;
  bool _loading = true;
  bool _busy = false;
  int _grubIndex = 0;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _swapMb.dispose();
    _swapDevice.dispose();
    _hosts.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/host/settings');
      final status = json as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _status = status;
        _hosts.text = status['hosts_content'] as String? ?? '';
        final entries = (status['grub_entries'] as List<dynamic>?) ?? const [];
        final current = int.tryParse(status['grub_default'] as String? ?? '0') ?? 0;
        _grubIndex = entries.isEmpty
            ? 0
            : current.clamp(0, entries.length - 1);
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

  Future<void> _post(
    String path,
    Map<String, dynamic> body, {
    String? success,
  }) async {
    setState(() => _busy = true);
    try {
      final json = await _api.postJson(
        path,
        body,
        timeout: const Duration(minutes: 3),
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (map['ok'] == false) {
        _toast(
          ((map['output'] as String?) ?? '操作失败').trim().isEmpty
              ? '操作失败'
              : (map['output'] as String).trim(),
        );
      } else {
        _toast(success ?? '已保存');
      }
      await _load();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveHosts() async {
    setState(() => _busy = true);
    try {
      final json = await _api.putJson('/api/v1/host/hosts', {
        'content': _hosts.text,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      _toast(map['ok'] == false ? '保存失败' : 'hosts 已保存');
      await _load();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return SizedBox(width: 720, child: const LoadingView());
    }
    if (_error != null) {
      return SizedBox(
        width: 720,
        child: ErrorBanner(message: _error!, onRetry: _load),
      );
    }
    final status = _status ?? const <String, dynamic>{};
    final ntpEnabled = status['ntp_enabled'] == true;
    final ntpSynced = status['ntp_synchronized'] == true;
    final entries =
        ((status['grub_entries'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList();
    final swapfileActive = status['swapfile_active'] == true;
    return SizedBox(
      width: 720,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          PanelCard(
            title: '交换分区',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row(
                  '当前交换',
                  '${formatBytes((status['swap_used_bytes'] as num?)?.toInt())} / '
                      '${formatBytes((status['swap_total_bytes'] as num?)?.toInt())}',
                ),
                _row(
                  '交换文件',
                  swapfileActive
                      ? '/swapfile · ${formatBytes((status['swapfile_bytes'] as num?)?.toInt())}'
                      : '未启用',
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    SizedBox(
                      width: 180,
                      child: TextField(
                        controller: _swapMb,
                        decoration: const InputDecoration(
                          labelText: '大小 (MiB)',
                          hintText: '2048',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    FilledButton(
                      onPressed: _busy ? null : _enableSwap,
                      child: const Text('启用 / 调整'),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton(
                      onPressed: _busy || !swapfileActive ? null : _disableSwap,
                      child: const Text('关闭'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '使用 /swapfile（64 MiB – 64 GiB），写入 /etc/fstab 后开机自动挂载。',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    SizedBox(
                      width: 240,
                      child: TextField(
                        controller: _swapDevice,
                        decoration: const InputDecoration(
                          labelText: '已有分区 / 设备',
                          hintText: '/dev/vg0/swap 或 /dev/sdb2',
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton(
                      onPressed: _busy ? null : _enableSwapDevice,
                      child: const Text('启用现有分区'),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  '仅对已格式化为 swap 的块设备执行 swapon，不会自动格式化分区。',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PanelCard(
            title: '时间同步',
            trailing: StatusPill(
              text: ntpSynced ? '已同步' : (ntpEnabled ? '同步中' : '未启用'),
              good: ntpSynced,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _row('时区', status['timezone'] as String? ?? '-'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  value: ntpEnabled,
                  onChanged: _busy
                      ? null
                      : (value) => _post(
                          '/api/v1/host/ntp',
                          {'enabled': value},
                          success: value ? '已启用 NTP 同步' : '已关闭 NTP 同步',
                        ),
                  title: const Text(
                    '启用 systemd-timesyncd / NTP 自动校时',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PanelCard(
            title: '启动项',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (entries.isEmpty)
                  Text(
                    '未找到 GRUB 配置，或当前系统不使用 GRUB。',
                    style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                  )
                else ...[
                  DropdownButtonFormField<int>(
                    initialValue: _grubIndex,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '默认启动项',
                      isDense: true,
                    ),
                    items: [
                      for (var i = 0; i < entries.length; i++)
                        DropdownMenuItem(
                          value: i,
                          child: Text(
                            entries[i],
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() => _grubIndex = value);
                    },
                  ),
                  const SizedBox(height: 10),
                  FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _post(
                            '/api/v1/host/grub',
                            {'index': _grubIndex},
                            success: '已更新默认启动项',
                          ),
                    child: const Text('设为默认并更新 GRUB'),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '写入 /etc/default/grub 的 GRUB_DEFAULT 并执行 update-grub。',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          PanelCard(
            title: '/etc/hosts',
            trailing: OutlinedButton(
              onPressed: _busy ? null : _saveHosts,
              child: const Text('保存'),
            ),
            child: TextField(
              controller: _hosts,
              minLines: 8,
              maxLines: 16,
              style: monospace.copyWith(fontSize: 12),
              decoration: const InputDecoration(
                hintText: '127.0.0.1 localhost',
                isDense: true,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _enableSwap() async {
    final size = int.tryParse(_swapMb.text.trim());
    if (size == null || size < 64 || size > 65536) {
      _toast('交换文件大小需在 64 到 65536 MiB 之间');
      return;
    }
    await _post(
      '/api/v1/host/swap',
      {'size_mb': size},
      success: '交换文件已启用（$size MiB）',
    );
  }

  Future<void> _disableSwap() => _post(
    '/api/v1/host/swap',
    {'size_mb': 0},
    success: '交换文件已关闭',
  );

  Future<void> _enableSwapDevice() async {
    final device = _swapDevice.text.trim();
    if (!device.startsWith('/dev/')) {
      _toast('请输入 /dev/ 下的块设备路径');
      return;
    }
    await _post(
      '/api/v1/host/swap-device',
      {'device': device},
      success: '$device 已启用为交换空间',
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace.copyWith(fontSize: 11.5, color: hampanelInkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
