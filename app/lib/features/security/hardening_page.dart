import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Host hardening: dangling links, umask, at/cron/sudo access and kernel
/// parameters.
///
/// Nothing here is applied blindly: the page shows the live value next to the
/// hardened recommendation, and each change is written to a managed drop-in so
/// it survives a reboot.
class HardeningPage extends StatefulWidget {
  const HardeningPage({super.key});

  @override
  State<HardeningPage> createState() => _HardeningPageState();
}

class _HardeningPageState extends State<HardeningPage> {
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
      final json = await _api.getJson('/api/v1/security/hardening');
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

  Future<void> _post(String path, Map<String, Object?> body) async {
    setState(() => _busy = true);
    try {
      final json = await _api.postJson(path, body);
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(
          content: Text(map['output'] as String? ?? '已应用'),
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

  Future<void> _pruneDangling(List<String> paths) async {
    if (paths.isEmpty) {
      showAppSnackBar(context, const SnackBar(content: Text('没有选中的空链接')));
      return;
    }
    final ok = await confirmDialog(
      context,
      title: '删除 ${paths.length} 个空链接？',
      message:
          '只删除目标确实不存在的符号链接；指向有效文件的链接会被跳过。'
          'systemd 的 .wants 目录里残留的链接也属于空链接。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    if (!mounted) return;
    await _post('/api/v1/security/hardening/dangling', {'paths': paths});
  }

  Future<void> _setUmask(String current) async {
    final controller = TextEditingController(text: current.isEmpty ? '027' : current);
    final value = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('设置默认 umask'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'umask 列出的是要移除的权限位：027 表示同组不可写、其他用户不可访问。'
              '新登录会话生效。',
              style: TextStyle(
                fontSize: 11.5,
                color: hampanelMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              decoration: const InputDecoration(labelText: 'umask（八进制）'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value == null || !mounted) return;
    await _post('/api/v1/security/hardening/umask', {'umask': value});
  }

  Future<void> _restrictTool(String tool, bool enabled) async {
    final controller = TextEditingController(text: 'root');
    final text = enabled
        ? await showDialog<String>(
            context: context,
            builder: (context) => AlertDialog(
              title: Text('限制 $tool 可用用户'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '写入 /etc/$tool.allow 后，只有列出的用户可以使用 $tool；'
                    '同时会删除对应的 deny 文件，避免审计时混淆。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    decoration: const InputDecoration(
                      labelText: '用户名（逗号分隔）',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(controller.text.trim()),
                  child: const Text('应用'),
                ),
              ],
            ),
          )
        : '';
    controller.dispose();
    if (text == null || !mounted) return;
    final users = text
        .split(',')
        .map((value) => value.trim())
        .where((value) => value.isNotEmpty)
        .toList();
    await _post('/api/v1/security/hardening/scheduler', {
      'tool': tool,
      'users': users,
      'enabled': enabled,
    });
  }

  @override
  Widget build(BuildContext context) {
    final status = _status ?? const <String, dynamic>{};
    final dangling = ((status['dangling'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final umask = status['umask'] as Map<String, dynamic>? ?? const {};
    final cron = status['cron'] as Map<String, dynamic>? ?? const {};
    final sudo = status['sudo'] as Map<String, dynamic>? ?? const {};
    final kernel = ((status['kernel'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final open = kernel.where((item) => item['hardened'] != true).toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('主机加固'),
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
                  title: '空链接',
                  trailing: Text(
                    '${dangling.length} 个',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '扫描 /etc、/opt、/srv、/var/tmp，找出目标已不存在的符号链接。'
                        '删除前会再次确认链接仍然断开。',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      if (dangling.isEmpty)
                        Text(
                          '未发现空链接。',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: hampanelMuted,
                          ),
                        )
                      else ...[
                        for (final entry in dangling.take(25))
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4),
                            child: Text(
                              '${entry['path']} → ${entry['target']}',
                              style: monospace.copyWith(fontSize: 11),
                            ),
                          ),
                        const SizedBox(height: 8),
                        OutlinedButton.icon(
                          onPressed: _busy
                              ? null
                              : () => _pruneDangling([
                                  for (final entry in dangling)
                                    entry['path'] as String,
                                ]),
                          icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                          label: Text('删除全部 ${dangling.length} 个空链接'),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '默认 umask',
                  trailing: StatusPill(
                    text: (umask['configured'] as String?)?.isNotEmpty == true
                        ? umask['configured'] as String
                        : '未设置',
                    good: (umask['configured'] as String?)?.isNotEmpty == true,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _row(
                        '开启会话应用',
                        umask['pam_umask'] == true ? 'pam_umask 可用' : 'pam_umask 缺失',
                      ),
                      _row(
                        'login.defs UMASK',
                        (umask['login_defs'] as String?)?.isNotEmpty == true
                            ? umask['login_defs'] as String
                            : '未设置',
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _setUmask(
                                umask['configured'] as String? ?? '',
                              ),
                        child: const Text('设置 umask'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: 'at / cron 访问控制',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _row('cron.allow', cron['cron_allow'] == true ? '存在' : '不存在'),
                      _row('cron.deny', cron['cron_deny'] == true ? '存在' : '不存在'),
                      _row('at.allow', cron['at_allow'] == true ? '存在' : '不存在'),
                      _row('at.deny', cron['at_deny'] == true ? '存在' : '不存在'),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          OutlinedButton(
                            onPressed:
                                _busy ? null : () => _restrictTool('cron', true),
                            child: const Text('限制 cron'),
                          ),
                          OutlinedButton(
                            onPressed: _busy ? null : () => _restrictTool('at', true),
                            child: const Text('限制 at'),
                          ),
                          TextButton(
                            onPressed: _busy
                                ? null
                                : () => _post(
                                    '/api/v1/security/hardening/scheduler',
                                    {'tool': 'cron', 'users': [], 'enabled': false},
                                  ),
                            child: const Text('移除 cron 限制'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: 'sudo',
                  trailing: StatusPill(
                    text: sudo['use_pty'] == true ? '已加固' : '未加固',
                    good: sudo['use_pty'] == true,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _row(
                        'sudoers 权限',
                        sudo['mode'] == null ? '—' : '${sudo['mode']}',
                      ),
                      _row(
                        'sudoers.d 可读文件',
                        '${((sudo['insecure'] as List<dynamic>?) ?? const []).length} 个',
                      ),
                      for (final path
                          in ((sudo['insecure'] as List<dynamic>?) ?? const [])
                              .whereType<String>())
                        Padding(
                          padding: const EdgeInsets.only(bottom: 4),
                          child: Text(
                            path,
                            style: monospace.copyWith(
                              fontSize: 11,
                              color: hampanelDanger,
                            ),
                          ),
                        ),
                      const SizedBox(height: 8),
                      OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _post(
                                '/api/v1/security/hardening/sudo',
                                const {},
                              ),
                        child: const Text('写入加固片段'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '内核参数',
                  trailing: Text(
                    '${open.length} 项待加固',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (status['sysctl_available'] != true)
                        Text(
                          status['message'] as String? ?? 'sysctl 不可用',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: hampanelDanger,
                          ),
                        ),
                      for (final item in kernel)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item['key'] as String? ?? '',
                                      style: monospace.copyWith(fontSize: 11.5),
                                    ),
                                    Text(
                                      item['description'] as String? ?? '',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: hampanelMuted,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    '${item['value']} / 建议 ${item['recommended']}',
                                    style: monospace.copyWith(
                                      fontSize: 11,
                                      color: item['hardened'] == true
                                          ? hampanelMuted
                                          : hampanelDanger,
                                    ),
                                  ),
                                  if (item['needs_review'] == true)
                                    Text(
                                      '需人工判断',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: hampanelDanger,
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      const SizedBox(height: 8),
                      FilledButton.icon(
                        onPressed:
                            _busy || status['sysctl_available'] != true
                            ? null
                            : () => _post(
                                '/api/v1/security/hardening/kernel',
                                {
                                  // Forwarding is excluded on purpose: turning it
                                  // off breaks container and router hosts.
                                  'params': [
                                    for (final item in kernel)
                                      if (item['needs_review'] != true)
                                        {
                                          'key': item['key'],
                                          'value': item['recommended'],
                                        },
                                  ],
                                },
                              ),
                        icon: const Icon(Icons.security_outlined, size: 16),
                        label: const Text('应用全部建议值'),
                      ),
                    ],
                  ),
                ),
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
            width: 130,
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
