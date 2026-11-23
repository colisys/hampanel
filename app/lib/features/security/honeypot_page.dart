import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// SSH / Web honeypot.
///
/// A guest runs under QEMU/KVM with the **host's identity** (CPU model, cores,
/// memory, DMI strings) but none of its hardware: storage is our own image and
/// networking is QEMU user-mode, so an attacker cannot reach the LAN.
class HoneypotPage extends StatefulWidget {
  const HoneypotPage({super.key, this.initialMode = 'web'});

  final String initialMode;

  @override
  State<HoneypotPage> createState() => _HoneypotPageState();
}

class _HoneypotPageState extends State<HoneypotPage> {
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  late String _mode = widget.initialMode;

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
      final json = await _api.getJson('/api/v1/security/honeypot');
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

  Future<void> _submit(
    String kind, {
    Map<String, dynamic>? params,
    String? title,
  }) async {
    final center = PanelScope.of(context).tasks;
    setState(() => _busy = true);
    try {
      final task = await center.submit(kind, params: params, title: title);
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text('已提交任务：${task.title}')),
      );
      final finished = await center.waitFor(task.id);
      if (!mounted) return;
      if (finished?.status != 'succeeded') {
        showAppSnackBar(
          context,
          SnackBar(content: Text('任务未成功：${finished?.status ?? 'unknown'}')),
        );
      }
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

  Future<void> _start() async {
    var selectedPort = _mode == 'ssh' ? '12222' : '18080';
    final portText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('启动蜜罐'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '确认在所有 IPv4 接口公开独立的 $_mode 蜜罐端口（1024–65535）。'
              '已占用端口将启动失败；不会修改防火墙、生产服务或重定向流量。'
              '${_mode == 'ssh' ? '仅发送 SSH 标识后断开，不进行密钥交换或登录。' : '仅提供静态 HTTP 状态页，无登录表单。'}',
              style: TextStyle(
                fontSize: 11.5,
                color: hampanelMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              initialValue: selectedPort,
              onChanged: (value) => selectedPort = value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '本机端口'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(selectedPort.trim()),
            child: const Text('确认公开并启动'),
          ),
        ],
      ),
    );

    if (portText == null) return;
    if (!mounted) return;
    final port = int.tryParse(portText);
    if (port == null || port < 1024 || port > 65535) {
      showAppSnackBar(context, const SnackBar(content: Text('端口不合法')));
      return;
    }
    await _submit(
      'security.honeypot.start',
      params: {'mode': _mode, 'port': port, 'confirmed': true},
      title: '启动蜜罐（$_mode）',
    );
  }

  Future<void> _stop(String id) async {
    setState(() => _busy = true);
    try {
      await _api.postJson('/api/v1/security/honeypot/stop', {'id': id});
      if (!mounted) return;
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

  Future<void> _showConsole(String id) async {
    try {
      final json = await _api.getJson('/api/v1/security/honeypot/console?id=$id');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('guest $id 控制台'),
          content: SizedBox(
            width: 720,
            height: 420,
            child: SingleChildScrollView(
              child: SelectableText(
                (map['content'] as String?)?.trim().isNotEmpty == true
                    ? map['content'] as String
                    : '（暂无输出）',
                style: monospace.copyWith(fontSize: 11.5, height: 1.5),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text(describeError(error))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status ?? const <String, dynamic>{};
    final qemu = status['qemu'] == true;
    final kvm = status['kvm'] == true;
    final imageReady = status['${_mode}_image_ready'] == true;
    final profile = status['profile'] as Map<String, dynamic>? ?? const {};
    final sessions = ((status['sessions'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final ready = qemu && imageReady && (status['kernel'] as String?)?.isNotEmpty == true;

    return Scaffold(
      appBar: AppBar(
        title: const Text('SSH / Web 蜜罐'),
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
                  title: '运行环境',
                  trailing: StatusPill(
                    text: ready ? '就绪' : '未就绪',
                    good: ready,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if ((status['message'] as String?)?.isNotEmpty == true)
                        InlineAlert(message: status['message'] as String),
                      const SizedBox(height: 10),
                      _row('QEMU', qemu ? '已安装' : '未安装'),
                      _row('KVM 加速', kvm ? '/dev/kvm 可用' : '未启用（软件模拟）'),
                      _row(
                        '宿主内核',
                        (status['kernel'] as String?)?.isNotEmpty == true
                            ? status['kernel'] as String
                            : '未找到',
                      ),
                      _row('guest 镜像', imageReady ? '已构建' : '未构建'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '复刻的硬件身份',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '下列为宿主参考配置；软件模拟使用虚拟 CPU，最多 2 核 / 1024 MB。'
                        '但所有设备均由 QEMU 模拟：没有磁盘或网卡透传，'
                        '网络为隔离的用户态网络，无法访问宿主所在局域网。',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.6,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _row('CPU', '${profile['cpu_model'] ?? '—'}'),
                      _row('核心数', '${profile['cpu_cores'] ?? '—'}'),
                      _row('内存', '${profile['memory_mb'] ?? '—'} MB'),
                      _row('存储', '仅内存文件系统，无磁盘挂载'),
                      _row('厂商', '${profile['vendor'] ?? '—'}'),
                      _row('型号', '${profile['product'] ?? '—'}'),
                      _row('序列号', '${profile['serial'] ?? '—'}'),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '运行控制',
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      DropdownButton<String>(
                        value: _mode,
                        items: const [
                          DropdownMenuItem(value: 'web', child: Text('Web 蜜罐')),
                          DropdownMenuItem(value: 'ssh', child: Text('SSH 蜜罐')),

                        ],
                        onChanged: _busy
                            ? null
                            : (value) => setState(() => _mode = value ?? 'web'),
                      ),
                      OutlinedButton.icon(
                        onPressed: _busy || !qemu
                            ? null
                            : () => _submit(
                                'security.honeypot.build',
                                params: {'mode': _mode},
                                title: '构建 guest 镜像',
                              ),
                        icon: const Icon(Icons.download_outlined, size: 16),
                        label: Text(imageReady ? '重新构建镜像' : '构建镜像'),
                      ),
                      FilledButton.icon(
                        onPressed: _busy || !ready ? null : _start,
                        icon: const Icon(Icons.play_circle_outlined, size: 16),
                        label: const Text('启动蜜罐'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '运行中的 guest',
                  trailing: Text(
                    '${sessions.where((s) => s['running'] == true).length} 个运行中',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  child: sessions.isEmpty
                      ? Text(
                          '暂无 guest。',
                          style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                        )
                      : Column(
                          children: [
                            for (final session in sessions)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '${session['id']} · ${session['mode']}',
                                            style: monospace.copyWith(
                                              fontSize: 11.5,
                                            ),
                                          ),
                                          Text(
                                            session['running'] == true
                                                ? '运行中 · 端口 ${session['port']}'
                                                : '已停止',
                                            style: TextStyle(
                                              fontSize: 11,
                                              color: hampanelMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    TextButton(
                                      onPressed: () =>
                                          _showConsole(session['id'] as String),
                                      child: const Text('控制台'),
                                    ),
                                    if (session['running'] == true)
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _stop(
                                                session['id'] as String,
                                              ),
                                        child: const Text('停止'),
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

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 96,
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
