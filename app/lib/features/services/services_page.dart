import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models/service.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ServicesPage extends StatefulWidget {
  const ServicesPage({super.key});

  @override
  State<ServicesPage> createState() => _ServicesPageState();
}

class _ServicesPageState extends State<ServicesPage> {
  List<ServiceInfo> _services = const [];
  String? _error;
  bool _loading = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => PanelScope.of(context).api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/services');
      final map = json as Map<String, dynamic>;
      final services = ((map['services'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ServiceInfo.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _services = services;
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

  Future<void> _run(ServiceInfo service, String action) async {
    try {
      final json = await _api.postJson(
        '/api/v1/services/${service.unit}/$action',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final output = (map['output'] as String? ?? '').trim();
      _toast(output.isEmpty ? '${service.unit}: $action 完成' : output);
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _showLogs(ServiceInfo service) async {
    try {
      final json = await _api.getJson(
        '/api/v1/services/${service.unit}/logs',
        query: {'lines': '300'},
      );
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => _ServiceLogsDialog(
          unit: service.unit,
          text: map['lines'] as String? ?? '',
        ),
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  List<ServiceInfo> get _filtered {
    if (_filter.trim().isEmpty) return _services;
    final needle = _filter.toLowerCase();
    return _services
        .where(
          (service) =>
              service.unit.toLowerCase().contains(needle) ||
              service.description.toLowerCase().contains(needle),
        )
        .toList();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '服务',
          subtitle: '共 ${_services.length} 个单元',
          actions: [
            SizedBox(
              width: 240,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索服务',
                  prefixIcon: Icon(Icons.search, size: 17),
                ),
                onChanged: (value) => setState(() => _filter = value),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  child: Card(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: SizedBox(
                        width: 1100,
                        child: SingleChildScrollView(
                          child: DataTable(
                            headingRowHeight: 38,
                            dataRowMinHeight: 34,
                            dataRowMaxHeight: 46,
                            columns: const [
                              DataColumn(label: Text('服务单元')),
                              DataColumn(label: Text('状态')),
                              DataColumn(label: Text('子状态')),
                              DataColumn(label: Text('描述')),
                              DataColumn(label: Text('操作')),
                            ],
                            rows: [
                              for (final service in _filtered)
                                DataRow(
                                  cells: [
                                    DataCell(
                                      Text(
                                        service.unit,
                                        style: monospace.copyWith(fontSize: 12),
                                      ),
                                    ),
                                    DataCell(
                                      StatusPill(
                                        text: service.active,
                                        good: service.running,
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        service.sub,
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: hampanelMuted,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 420,
                                        ),
                                        child: Text(
                                          service.description,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          PopupMenuButton<String>(
                                            tooltip: '操作',
                                            icon: const Icon(
                                              Icons.more_horiz,
                                              size: 18,
                                            ),
                                            onSelected: (value) =>
                                                _run(service, value),
                                            itemBuilder: (context) => const [
                                              PopupMenuItem(
                                                value: 'start',
                                                child: Text('启动'),
                                              ),
                                              PopupMenuItem(
                                                value: 'stop',
                                                child: Text('停止'),
                                              ),
                                              PopupMenuItem(
                                                value: 'restart',
                                                child: Text('重启'),
                                              ),
                                              PopupMenuItem(
                                                value: 'reload',
                                                child: Text('重载'),
                                              ),
                                              PopupMenuItem(
                                                value: 'enable',
                                                child: Text('开机自启'),
                                              ),
                                              PopupMenuItem(
                                                value: 'disable',
                                                child: Text('取消自启'),
                                              ),
                                            ],
                                          ),
                                          IconButton(
                                            tooltip: '日志',
                                            onPressed: () => _showLogs(service),
                                            icon: const Icon(
                                              Icons.receipt_long_outlined,
                                              size: 17,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ServiceLogsDialog extends StatefulWidget {
  const _ServiceLogsDialog({required this.unit, required this.text});

  final String unit;
  final String text;

  @override
  State<_ServiceLogsDialog> createState() => _ServiceLogsDialogState();
}

class _ServiceLogsDialogState extends State<_ServiceLogsDialog> {
  final _search = TextEditingController();
  String _query = '';
  int _limit = 500;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<String> get _allLines {
    if (widget.text.trim().isEmpty) return const [];
    return widget.text.split('\n');
  }

  List<String> get _visibleLines {
    final all = _allLines;
    final windowed = _limit > 0 && all.length > _limit
        ? all.sublist(all.length - _limit)
        : all;
    if (_query.trim().isEmpty) return windowed;
    final needle = _query.toLowerCase();
    return windowed
        .where((line) => line.toLowerCase().contains(needle))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final all = _allLines;
    final visible = _visibleLines;
    return AlertDialog(
      title: Text('${widget.unit} 日志'),
      content: DialogBody(
        maxWidth: 960,
        maxHeight: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      hintText: '搜索日志内容',
                      prefixIcon: Icon(Icons.search, size: 17),
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ),
                const SizedBox(width: 10),
                DropdownButton<int>(
                  value: _limit,
                  underline: const SizedBox.shrink(),
                  items: const [
                    DropdownMenuItem(value: 200, child: Text('最后 200 行')),
                    DropdownMenuItem(value: 500, child: Text('最后 500 行')),
                    DropdownMenuItem(value: 1000, child: Text('最后 1000 行')),
                    DropdownMenuItem(value: 5000, child: Text('最后 5000 行')),
                    DropdownMenuItem(value: 0, child: Text('全部')),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => _limit = value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              all.isEmpty
                  ? '暂无日志输出'
                  : '共 ${all.length} 行 · 显示 ${visible.length} 行',
              style: TextStyle(fontSize: 11, color: hampanelMuted),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hampanelSurfaceAlt,
                  border: Border.all(color: hampanelBorder),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    visible.isEmpty
                        ? '没有匹配的日志行'
                        : localizeLogTimestamps(visible.join('\n')),
                    style: monospace,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: visible.isEmpty
              ? null
              : () =>
                    Clipboard.setData(ClipboardData(text: visible.join('\n'))),
          child: const Text('复制显示内容'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
