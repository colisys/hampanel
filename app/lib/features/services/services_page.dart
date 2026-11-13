import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
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
        builder: (context) => AlertDialog(
          title: Text('${service.unit} 日志'),
          content: SizedBox(
            width: 860,
            height: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                (map['lines'] as String? ?? '').isEmpty
                    ? '暂无日志输出'
                    : map['lines'] as String,
                style: monospace,
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
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
