import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Passive scan sensing. The sensor is an eBPF program on the host; this page
/// reports whether that pipeline can run, the sources it observed and the ones
/// it banned, and lets the operator install, start or stop the probe.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
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
      final status = await _api.getJson('/api/v1/security/scan');
      if (!mounted) return;
      setState(() {
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

  Future<void> _post(String path, {Map<String, Object?>? body}) async {
    setState(() => _busy = true);
    try {
      await _api.postJson(path, body ?? const {});
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

  Future<void> _unban(String source) async {
    final ok = await confirmDialog(
      context,
      title: '解除封禁？',
      message: '将从黑名单移除 $source，并删除对应的防火墙拒绝规则。',
      confirmLabel: '解除',
    );
    if (!ok) return;
    await _post('/api/v1/security/scan/unban', body: {'source': source});
  }

  @override
  Widget build(BuildContext context) {
    final status = _status ?? const <String, dynamic>{};
    final ebpf = status['ebpf'] == true;
    final installed = status['scanner_installed'] == true;
    final running = status['scanner_running'] == true;
    final bpftrace = status['bpftrace_available'] == true;
    final hits = ((status['hits'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final banned = ((status['banned'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList();

    return Scaffold(
      appBar: AppBar(
        title: const Text('扫描感知'),
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
                  title: '采集能力',
                  trailing: StatusPill(
                    text: running ? '采集中' : (ebpf ? '可用' : '不可用'),
                    good: ebpf,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status['message'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _row('内核 BPF', status['kernel_bpf'] == true ? '已启用' : '未启用'),
                      _row('bpftrace', bpftrace ? '已安装' : '未安装'),
                      _row(
                        '权限',
                        // Only non-root users are gated by this sysctl, so a
                        // root daemon is reported from its own capability.
                        ebpf ? '可加载探针' : '不可加载探针',
                      ),
                      _row(
                        '探针',
                        !installed
                            ? '未安装'
                            : (running ? '已安装 · 运行中' : '已安装 · 已停止'),
                      ),
                      if (ebpf) ...[
                        const SizedBox(height: 4),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            if (!installed)
                              FilledButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _post(
                                        '/api/v1/security/scan/install',
                                      ),
                                icon: const Icon(Icons.download_outlined, size: 16),
                                label: const Text('安装探针'),
                              )
                            else if (running)
                              OutlinedButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _post('/api/v1/security/scan/stop'),
                                icon: const Icon(Icons.stop_circle_outlined, size: 16),
                                label: const Text('停止采集'),
                              )
                            else
                              FilledButton.icon(
                                onPressed: _busy
                                    ? null
                                    : () => _post('/api/v1/security/scan/start'),
                                icon: const Icon(Icons.play_circle_outlined, size: 16),
                                label: const Text('开始采集'),
                              ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (!ebpf)
                  PanelCard(
                    title: '为什么不能用',
                    child: Text(
                      '被动扫描感知依赖 eBPF：daemon 需要以 root 运行，内核需启用 '
                      'BPF syscall 与 BTF，且服务器需安装 bpftrace。',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hampanelMuted,
                        height: 1.6,
                      ),
                    ),
                  )
                else ...[
                  PanelCard(
                    title: '自动拉黑的来源',
                    trailing: Text(
                      '${banned.length} 个',
                      style: TextStyle(fontSize: 11, color: hampanelMuted),
                    ),
                    child: banned.isEmpty
                        ? Text(
                            '暂无自动拉黑记录。',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: hampanelMuted,
                            ),
                          )
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (final source in banned)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          source,
                                          style: monospace.copyWith(
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: _busy
                                            ? null
                                            : () => _unban(source),
                                        child: const Text('解除'),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  PanelCard(
                    title: '观测到的连接',
                    trailing: Text(
                      '最近 ${hits.length} 条',
                      style: TextStyle(fontSize: 11, color: hampanelMuted),
                    ),
                    child: hits.isEmpty
                        ? Text(
                            '暂无观测记录。',
                            style: TextStyle(
                              fontSize: 11.5,
                              color: hampanelMuted,
                            ),
                          )
                        : Column(
                            children: [
                              for (final hit in hits.reversed)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${hit['source']} → :${hit['port']}',
                                          style: monospace.copyWith(
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '${hit['count']} 次',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: hampanelMuted,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      StatusPill(
                                        text: banned.contains(hit['source'])
                                            ? '已拉黑'
                                            : '观察中',
                                        good:
                                            !banned.contains(hit['source']),
                                      ),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                  ),
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
            width: 110,
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
