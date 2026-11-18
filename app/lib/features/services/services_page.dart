import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/service.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/widgets.dart';
import 'service_card.dart';
import 'service_edit_page.dart';
import 'service_logs_page.dart';

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
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServiceLogsPage(
          api: _api,
          unit: service.unit,
          title: '${service.unit} 日志',
        ),
      ),
    );
  }

  Future<void> _openEditor(ServiceInfo service) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ServiceEditPage(api: _api, service: service),
      ),
    );
    await _load();
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

  Widget _serviceCards() {
    final services = _filtered;
    return ListView.separated(
      padding: pageContentPadding(context, top: 0),
      itemCount: services.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final service = services[index];
        return ServiceCard(
          service: service,
          onAction: (action) => _run(service, action),
          onEdit: () => _openEditor(service),
          onLogs: () => _showLogs(service),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
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
            PageRefreshButton(onPressed: _load, refreshing: _loading),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : compact
              ? _serviceCards()
              : Padding(
                  padding: pageContentPadding(context, top: 4),
                  child: Card(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
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
                                      ServiceActions(
                                        onAction: (action) =>
                                            _run(service, action),
                                        onEdit: () => _openEditor(service),
                                        onLogs: () => _showLogs(service),
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
      ],
    );
  }
}
