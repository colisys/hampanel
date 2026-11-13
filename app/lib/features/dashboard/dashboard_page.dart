import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models/metrics.dart';
import '../../core/models/system_info.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  SystemInfo? _info;
  Metrics? _metrics;
  String? _error;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _refreshMetrics(),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final api = PanelScope.of(context).api;
    try {
      final results = await Future.wait([
        api.getJson('/api/v1/system'),
        api.getJson('/api/v1/metrics'),
      ]);
      if (!mounted) return;
      setState(() {
        _info = SystemInfo.fromJson(results[0] as Map<String, dynamic>);
        _metrics = Metrics.fromJson(results[1] as Map<String, dynamic>);
        _error = null;
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

  Future<void> _refreshMetrics() async {
    final api = PanelScope.of(context).api;
    try {
      final json = await api.getJson('/api/v1/metrics');
      if (!mounted) return;
      setState(() => _metrics = Metrics.fromJson(json as Map<String, dynamic>));
    } catch (_) {
      // polling failures are surfaced by the manual refresh path
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '概览',
          subtitle: _info == null
              ? '正在读取服务器状态'
              : '${_info!.hostname} · ${_info!.os}',
          actions: [
            IconButton(
              onPressed: _refresh,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _refresh),
        Expanded(
          child: _loading
              ? const LoadingView()
              : SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  child: Wrap(
                    spacing: 14,
                    runSpacing: 14,
                    children: [
                      SizedBox(width: 340, child: _hostCard()),
                      SizedBox(width: 300, child: _cpuCard()),
                      SizedBox(width: 300, child: _memoryCard()),
                      SizedBox(width: 300, child: _networkCard()),
                      SizedBox(width: double.infinity, child: _diskCard()),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _hostCard() {
    final info = _info;
    if (info == null) return const PanelCard(child: SizedBox(height: 120));
    return PanelCard(
      title: '主机',
      child: Column(
        children: [
          _row('主机名', info.hostname),
          _row('系统', info.os),
          _row('内核', info.kernel),
          _row('架构', info.arch),
          _row('CPU', info.cpuModel, maxLines: 2),
          _row('核心', '${info.cores}'),
          _row('运行', formatDuration(info.uptimeSeconds)),
          _row('面板', info.panelVersion),
        ],
      ),
    );
  }

  Widget _cpuCard() {
    final cpu = _metrics?.cpu;
    return PanelCard(
      title: '处理器',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatTile(
            label: '使用率',
            value: formatPercent(cpu?.usagePercent),
            detail: '${cpu?.cores ?? 0} 个逻辑核心',
            accent: hampanelAccent,
          ),
          const SizedBox(height: 12),
          StyledProgress(value: (cpu?.usagePercent ?? 0) / 100),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(child: _loadBadge('1 分钟', cpu?.load1)),
              Expanded(child: _loadBadge('5 分钟', cpu?.load5)),
              Expanded(child: _loadBadge('15 分钟', cpu?.load15)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _loadBadge(String label, double? value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 10.5, color: hampanelMuted),
        ),
        const SizedBox(height: 3),
        Text(
          (value ?? 0).toStringAsFixed(2),
          style: monospace.copyWith(fontSize: 14),
        ),
      ],
    );
  }

  Widget _memoryCard() {
    final memory = _metrics?.memory;
    return PanelCard(
      title: '内存',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          StatTile(
            label: '已用',
            value: formatBytes(memory?.usedBytes),
            detail:
                '共 ${formatBytes(memory?.totalBytes)} · ${formatPercent(memory?.percent)}',
          ),
          const SizedBox(height: 12),
          StyledProgress(value: (memory?.percent ?? 0) / 100),
          const SizedBox(height: 14),
          _row('可用', formatBytes(memory?.availableBytes)),
          _row(
            '交换分区',
            '${formatBytes(memory?.swapUsedBytes)} / ${formatBytes(memory?.swapTotalBytes)}',
          ),
        ],
      ),
    );
  }

  Widget _networkCard() {
    final net = _metrics?.network;
    return PanelCard(
      title: '网络',
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '下行',
                  value: '${formatBytes(net?.rxRateBps)}/s',
                  detail: '累计 ${formatBytes(net?.rxBytes)}',
                  accent: hampanelAccent,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: '上行',
                  value: '${formatBytes(net?.txRateBps)}/s',
                  detail: '累计 ${formatBytes(net?.txBytes)}',
                  accent: hampanelAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '速率每 3 秒采样一次，仅统计非回环接口',
            style: TextStyle(fontSize: 10.5, color: hampanelMuted),
          ),
        ],
      ),
    );
  }

  Widget _diskCard() {
    final disks = _metrics?.disks ?? const <DiskMetrics>[];
    if (disks.isEmpty) {
      return const PanelCard(
        title: '磁盘',
        child: Text(
          '未发现可用的块设备',
          style: TextStyle(color: hampanelMuted, fontSize: 12),
        ),
      );
    }
    return PanelCard(
      title: '磁盘',
      child: Column(
        children: [
          for (final disk in disks)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        disk.mount,
                        style: monospace.copyWith(
                          fontSize: 13,
                          color: hampanelInk,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        disk.filesystem,
                        style: const TextStyle(
                          fontSize: 10.5,
                          color: hampanelMuted,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${formatBytes(disk.usedBytes)} / ${formatBytes(disk.totalBytes)} · ${formatPercent(disk.percent)}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: hampanelMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  StyledProgress(
                    value: disk.percent / 100,
                    color: disk.percent > 90 ? hampanelDanger : hampanelAccent,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(String label, String value, {int maxLines = 1}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 62,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: const TextStyle(fontSize: 11.5, color: hampanelInkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
