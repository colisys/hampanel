import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/security.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Passive scanning sensor. The sensor itself is an eBPF program on the host;
/// this page reports whether that pipeline can run and, when it can, the
/// sources it observed and auto-banned.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage> {
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
      final status = await _api.getJson('/api/v1/security/scan');
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

  @override
  Widget build(BuildContext context) {
    final caps = _capabilities;
    final status = _status;
    final hits = ((status?['hits'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final banned = ((status?['banned'] as List<dynamic>?) ?? const [])
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
                    text: caps?.ebpf == true ? '可用' : '不可用',
                    good: caps?.ebpf == true,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        status?['message'] as String? ?? '',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 10),
                      _row('内核 BPF', status?['kernel_bpf'] == true ? '已启用' : '未启用'),
                      _row(
                        '非特权 BPF',
                        switch (status?['unprivileged_disabled']) {
                          0 => '允许',
                          1 => '受限',
                          2 => '禁止',
                          _ => '未知',
                        },
                      ),
                      _row(
                        '探针',
                        status?['scanner_installed'] == true
                            ? (status?['scanner_running'] == true
                                  ? '已安装 · 运行中'
                                  : '已安装 · 未运行')
                            : '未构建',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                if (caps?.ebpf != true)
                  PanelCard(
                    title: '为什么不能用',
                    child: Text(
                      '被动扫描感知依赖 eBPF：daemon 需要以 root 运行，内核需启用 BPF syscall 与 BTF，'
                      '且探针需要在本机编译。可在「设置 → 安全组件」中一键安装依赖。',
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
                        : Wrap(
                            spacing: 8,
                            runSpacing: 6,
                            children: [
                              for (final ip in banned)
                                Chip(
                                  label: Text(
                                    ip,
                                    style: monospace.copyWith(fontSize: 11),
                                  ),
                                ),
                            ],
                          ),
                  ),
                  const SizedBox(height: 12),
                  PanelCard(
                    title: '观测到的扫描',
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
                              for (final hit in hits)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 8),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          '${hit['source']} → ${hit['target']}:${hit['port']}',
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
                                        text: hit['banned'] == true
                                            ? '已拉黑'
                                            : '观察中',
                                        good: hit['banned'] != true,
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
