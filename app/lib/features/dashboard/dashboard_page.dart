import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/client_settings.dart';
import '../../core/format.dart';
import '../../core/models/metrics.dart';
import '../../core/models/system_info.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/widgets.dart';

const _historyLimit = 60;

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

  final List<double> _cpuHistory = [];
  final List<double> _loadHistory = [];
  final List<double> _memoryHistory = [];
  final Map<String, List<double>> _rxHistory = {};
  final Map<String, List<double>> _txHistory = {};
  String? _iface;

  @override
  void initState() {
    super.initState();
    ClientSettings.instance.addListener(_onSettingsChanged);
    ClientSettings.instance.load();
    _refresh();
  }

  @override
  void dispose() {
    ClientSettings.instance.removeListener(_onSettingsChanged);
    _timer?.cancel();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    if (_timer != null) {
      _timer!.cancel();
      _timer = null;
      _ensurePolling();
    }
    setState(() {});
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
        _recordHistory();
      });
      _ensurePolling();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
      _timer?.cancel();
      _timer = null;
    }
  }

  /// 采样循环只在拿到过一次成功数据后启动；连接失败时不空转轮询。
  void _ensurePolling() {
    if (_timer != null) return;
    _timer = Timer.periodic(
      Duration(seconds: ClientSettings.instance.overviewRefreshSeconds),
      (_) => _refreshMetrics(),
    );
  }

  Future<void> _refreshMetrics() async {
    final api = PanelScope.of(context).api;
    try {
      final json = await api.getJson('/api/v1/metrics');
      if (!mounted) return;
      setState(() {
        _metrics = Metrics.fromJson(json as Map<String, dynamic>);
        _recordHistory();
      });
    } catch (_) {
      // polling failures are surfaced by the manual refresh path
    }
  }

  void _recordHistory() {
    final metrics = _metrics;
    if (metrics == null) return;
    _push(_cpuHistory, metrics.cpu.usagePercent);
    _push(_loadHistory, metrics.cpu.load1);
    _push(_memoryHistory, metrics.memory.percent);
    for (final iface in metrics.network.interfaces) {
      _push(
        _rxHistory.putIfAbsent(iface.name, () => <double>[]),
        iface.rxRateBps,
      );
      _push(
        _txHistory.putIfAbsent(iface.name, () => <double>[]),
        iface.txRateBps,
      );
    }
    final interfaces = metrics.network.interfaces;
    if (interfaces.isNotEmpty &&
        (_iface == null || !interfaces.any((item) => item.name == _iface))) {
      _iface = interfaces.first.name;
    }
  }

  static void _push(List<double> values, double value) {
    values.add(value.isFinite ? value : 0);
    if (values.length > _historyLimit) {
      values.removeRange(0, values.length - _historyLimit);
    }
  }

  InterfaceMetrics? get _selectedInterface {
    final interfaces =
        _metrics?.network.interfaces ?? const <InterfaceMetrics>[];
    for (final iface in interfaces) {
      if (iface.name == _iface) return iface;
    }
    return interfaces.isEmpty ? null : interfaces.first;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '概览',
          actions: [
            PageRefreshButton(onPressed: _refresh),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _refresh),
        Expanded(
          child: _loading
              ? const LoadingView()
              : SingleChildScrollView(
                  padding: pageContentPadding(context, top: 4),
                  child: _cards(),
                ),
        ),
      ],
    );
  }

  Widget _cards() {
    final cards = <Widget>[
      _hostCard(),
      _cpuCard(),
      _memoryCard(),
      _networkCard(),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth >= 1080) {
          return Column(
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (var i = 0; i < cards.length; i++) ...[
                      Expanded(child: cards[i]),
                      if (i != cards.length - 1) const SizedBox(width: 14),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 14),
              _diskCard(),
            ],
          );
        }
        return Wrap(
          spacing: 14,
          runSpacing: 14,
          children: [
            for (final card in cards) SizedBox(width: 330, child: card),
            SizedBox(width: double.infinity, child: _diskCard()),
          ],
        );
      },
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
          const SizedBox(height: 12),
          Sparkline(values: _cpuHistory, color: hampanelAccent),
          const SizedBox(height: 6),
          Text(
            '近期 CPU（每 3 秒采样）',
            style: TextStyle(fontSize: 10.5, color: hampanelMuted),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(child: _loadBadge('1 分钟', cpu?.load1)),
              Expanded(child: _loadBadge('5 分钟', cpu?.load5)),
              Expanded(child: _loadBadge('15 分钟', cpu?.load15)),
            ],
          ),
          const SizedBox(height: 8),
          Sparkline(values: _loadHistory, color: hampanelMuted, height: 28),
          const SizedBox(height: 4),
          Text(
            '近期负载（1 分钟）',
            style: TextStyle(fontSize: 10.5, color: hampanelMuted),
          ),
        ],
      ),
    );
  }

  Widget _loadBadge(String label, double? value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10.5, color: hampanelMuted)),
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
          const SizedBox(height: 12),
          Sparkline(values: _memoryHistory, color: hampanelAccent, maxValue: 100),
          const SizedBox(height: 6),
          Text(
            '近期内存使用率',
            style: TextStyle(fontSize: 10.5, color: hampanelMuted),
          ),
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
    final network = _metrics?.network;
    final interfaces = network?.interfaces ?? const <InterfaceMetrics>[];
    final selected = _selectedInterface;
    final rx = _rxHistory[selected?.name] ?? const <double>[];
    final tx = _txHistory[selected?.name] ?? const <double>[];
    return PanelCard(
      title: '网络',
      trailing: interfaces.isEmpty
          ? null
          : SizedBox(
              width: 128,
              child: DropdownButton<String>(
                value: selected?.name,
                isExpanded: true,
                isDense: true,
                underline: const SizedBox.shrink(),
                style: TextStyle(fontSize: 11.5, color: hampanelInk),
                items: [
                  for (final iface in interfaces)
                    DropdownMenuItem(
                      value: iface.name,
                      child: Text(
                        iface.name,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 11.5),
                      ),
                    ),
                ],
                onChanged: (value) {
                  if (value == null) return;
                  setState(() => _iface = value);
                },
              ),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: StatTile(
                  label: '下行',
                  value:
                      '${formatBytes(selected?.rxRateBps ?? network?.rxRateBps)}/s',
                  detail:
                      '累计 ${formatBytes(selected?.rxBytes ?? network?.rxBytes)}',
                  accent: hampanelAccent,
                ),
              ),
              Expanded(
                child: StatTile(
                  label: '上行',
                  value:
                      '${formatBytes(selected?.txRateBps ?? network?.txRateBps)}/s',
                  detail:
                      '累计 ${formatBytes(selected?.txBytes ?? network?.txBytes)}',
                  accent: hampanelAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Sparkline(
            values: rx,
            color: hampanelAccent,
            secondary: tx,
            secondaryColor: hampanelMuted,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              _legend('下行', hampanelAccent),
              const SizedBox(width: 12),
              _legend('上行', hampanelMuted),
            ],
          ),
        ],
      ),
    );
  }

  Widget _legend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 8, height: 8, color: color),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10.5, color: hampanelMuted)),
      ],
    );
  }

  Widget _diskCard() {
    final disks = _metrics?.disks ?? const <DiskMetrics>[];
    if (disks.isEmpty) {
      return PanelCard(
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
                        style: TextStyle(fontSize: 10.5, color: hampanelMuted),
                      ),
                      const Spacer(),
                      Text(
                        '${formatBytes(disk.usedBytes)} / ${formatBytes(disk.totalBytes)} · ${formatPercent(disk.percent)}',
                        style: TextStyle(fontSize: 11, color: hampanelMuted),
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
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11.5, color: hampanelInkSoft),
            ),
          ),
        ],
      ),
    );
  }
}

/// 轻量折线图，用于概览页的近期趋势；不引入额外图表依赖。
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.secondary,
    this.secondaryColor,
    this.maxValue,
    this.height = 40,
  });

  final List<double> values;
  final Color color;
  final List<double>? secondary;
  final Color? secondaryColor;
  final double? maxValue;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _SparkPainter(
          values: values,
          color: color,
          secondary: secondary,
          secondaryColor: secondaryColor ?? color,
          maxValue: maxValue,
        ),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter({
    required this.values,
    required this.color,
    this.secondary,
    required this.secondaryColor,
    required this.maxValue,
  });

  final List<double> values;
  final Color color;
  final List<double>? secondary;
  final Color secondaryColor;
  final double? maxValue;

  @override
  void paint(Canvas canvas, Size size) {
    final background = Paint()
      ..color = hampanelBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      background,
    );

    var max = maxValue ?? 1.0;
    for (final value in values) {
      if (value > max) max = value;
    }
    for (final value in secondary ?? const <double>[]) {
      if (value > max) max = value;
    }

    _line(canvas, size, values, color, max);
    if (secondary != null && secondary!.isNotEmpty) {
      _line(canvas, size, secondary!, secondaryColor, max);
    }
  }

  void _line(
    Canvas canvas,
    Size size,
    List<double> data,
    Color lineColor,
    double max,
  ) {
    if (data.length < 2) {
      if (data.length == 1) {
        canvas.drawCircle(
          Offset(size.width - 2, size.height / 2),
          2,
          Paint()..color = lineColor,
        );
      }
      return;
    }
    final path = Path();
    final step = size.width / (data.length - 1);
    for (var i = 0; i < data.length; i++) {
      final x = i * step;
      final y = size.height - (data[i] / max).clamp(0.0, 1.0) * size.height;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = lineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.secondary != secondary ||
      oldDelegate.color != color;
}
