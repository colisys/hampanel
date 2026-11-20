import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Active reconnaissance of one host.
///
/// A scan sends packets from the panel itself and can take minutes, so it is
/// submitted as a task and the report is read from the task result instead of
/// holding a request open.
class ProbePage extends StatefulWidget {
  const ProbePage({super.key});

  @override
  State<ProbePage> createState() => _ProbePageState();
}

class _ProbePageState extends State<ProbePage> {
  final _target = TextEditingController();
  bool _full = false;
  bool _osDetection = true;
  bool _busy = false;
  bool _statusLoading = true;
  bool _nmap = false;
  String? _error;
  String? _statusMessage;

  Map<String, dynamic>? _report;
  String? _output;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _target.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() => _statusLoading = true);
    try {
      final json = await _api.getJson('/api/v1/security/probe');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _nmap = map['nmap'] == true;
        _statusLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _statusMessage = describeError(error);
        _statusLoading = false;
      });
    }
  }

  Future<void> _probe() async {
    final target = _target.text.trim();
    if (target.isEmpty) {
      showAppSnackBar(
        context,
        const SnackBar(content: Text('请输入目标 IPv4 / IPv6 或主机名')),
      );
      return;
    }
    final ok = await confirmDialog(
      context,
      title: '对 $target 发起主动探测？',
      message:
          '面板将从本机直接向目标发送探测报文；'
          '请确认你有权扫描该目标。探测可能持续数分钟。',
      confirmLabel: '开始探测',
    );
    if (!ok) return;
    if (!mounted) return;

    final center = PanelScope.of(context).tasks;
    setState(() {
      _busy = true;
      _error = null;
      _report = null;
      _output = null;
    });
    try {
      final task = await center.submit(
        'security.probe',
        params: {
          'target': target,
          'intensity': _full ? 'full' : 'fast',
          'os_detection': _osDetection,
        },
        title: '探测 $target',
      );
      if (!mounted) return;
      final finished = await center.waitFor(task.id);
      if (!mounted) return;
      final detail = await _api.getJson('/api/v1/tasks/${task.id}');
      final map = detail as Map<String, dynamic>? ?? const {};
      setState(() {
        _output = map['output'] as String?;
        _report = _decodeResult(map['result']);
        _busy = false;
      });
      final status = finished?.status ?? 'unknown';
      if (status != 'succeeded' && mounted) {
        showAppSnackBar(
          context,
          SnackBar(
            content: Text('探测未成功：${map['error'] ?? status}'),
          ),
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _busy = false;
      });
    }
  }

  /// The task detail returns `output` as plain text and `result` as JSON text.
  Map<String, dynamic>? _decodeResult(Object? raw) {
    if (raw is Map<String, dynamic>) return raw;
    if (raw is String && raw.isNotEmpty) {
      try {
        final decoded = jsonDecode(raw);
        return decoded is Map<String, dynamic> ? decoded : null;
      } catch (_) {
        return null;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('主机探测')),
      body: ListView(
        padding: pageContentPadding(context),
        children: [
          PanelCard(
            title: '目标',
            trailing: _statusLoading
                ? null
                : StatusPill(text: _nmap ? 'nmap 可用' : '无 nmap', good: _nmap),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: _target,
                  decoration: const InputDecoration(
                    labelText: 'IPv4 / IPv6 / 主机名',
                    hintText: '例如 192.0.2.10 或 2001:db8::1',
                  ),
                  onSubmitted: (_) => _busy ? null : _probe(),
                ),
                const SizedBox(height: 8),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('全端口扫描'),
                  subtitle: const Text('关闭时只扫描常见端口，速度更快'),
                  value: _full,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _full = value),
                ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('系统指纹'),
                  subtitle: const Text('需要 root 权限；IPv6 目标通常无法得出结论'),
                  value: _osDetection,
                  onChanged: _busy
                      ? null
                      : (value) => setState(() => _osDetection = value),
                ),
                const SizedBox(height: 8),
                if (_statusMessage != null) ...[
                  Text(
                    _statusMessage!,
                    style: TextStyle(fontSize: 11.5, color: hampanelDanger),
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  _nmap
                      ? '探测使用 nmap 主动扫描，并补充 Shodan InternetDB 被动情报。'
                      : '未安装 nmap：只能返回被动情报，无法主动扫描端口。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: _busy ? null : _probe,
                  icon: const Icon(Icons.radar_outlined, size: 16),
                  label: Text(_busy ? '探测中…' : '开始探测'),
                ),
              ],
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            ErrorBanner(message: _error!, onRetry: _probe),
          ],
          if (_output != null) ...[
            const SizedBox(height: 12),
            PanelCard(
              title: '结果',
              child: SelectableText(
                _output!,
                style: monospace.copyWith(fontSize: 11.5, height: 1.5),
              ),
            ),
          ],
          if (_report != null) ...[
            const SizedBox(height: 12),
            _reportCard(_report!),
          ],
          if (_busy) ...[
            const SizedBox(height: 16),
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _reportCard(Map<String, dynamic> report) {
    final ports = ((report['ports'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final intel = report['intel'] as Map<String, dynamic>?;
    final hostnames = ((report['hostnames'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList();
    return PanelCard(
      title: '被动情报与开放端口',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (hostnames.isNotEmpty) _row('主机名', hostnames.join(', ')),
          _row(
            '系统猜测',
            (report['os_guess'] as String?)?.isNotEmpty == true
                ? '${report['os_guess']}（${report['os_accuracy']}%）'
                : '无可靠结论',
          ),
          _row('开放端口', '${ports.length}'),
          if (intel != null) ...[
            _row(
              '被动标签',
              ((intel['tags'] as List<dynamic>?) ?? const []).join(', '),
            ),
            _row(
              '已知漏洞',
              '${((intel['vulns'] as List<dynamic>?) ?? const []).length}',
            ),
          ],
          if (ports.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final port in ports)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${port['port']}/${port['protocol']} '
                  '${port['service'] ?? ''} ${port['product'] ?? ''} '
                  '${port['version'] ?? ''}'
                      .trim(),
                  style: monospace.copyWith(fontSize: 11.5),
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
        crossAxisAlignment: CrossAxisAlignment.start,
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
