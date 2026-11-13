import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models/process_info.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ProcessesPage extends StatefulWidget {
  const ProcessesPage({super.key});

  @override
  State<ProcessesPage> createState() => _ProcessesPageState();
}

class _ProcessesPageState extends State<ProcessesPage> {
  ProcessList? _list;
  String? _error;
  bool _loading = true;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final json = await PanelScope.of(context).api
          .getJson('/api/v1/processes', query: {'limit': '200'});
      if (!mounted) return;
      setState(() {
        _list = ProcessList.fromJson(json as Map<String, dynamic>);
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

  List<ProcessInfo> get _filtered {
    final items = _list?.processes ?? const <ProcessInfo>[];
    if (_filter.trim().isEmpty) return items;
    final needle = _filter.toLowerCase();
    return items
        .where(
          (process) =>
              process.name.toLowerCase().contains(needle) ||
              process.command.toLowerCase().contains(needle) ||
              process.pid.toString() == needle,
        )
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '进程',
          subtitle: '共 ${_list?.total ?? 0} 个进程，按内存占用排序',
          actions: [
            SizedBox(
              width: 240,
              child: TextField(
                decoration: const InputDecoration(
                  hintText: '搜索名称 / PID / 命令',
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
                        width: 1180,
                        child: SingleChildScrollView(
                          child: DataTable(
                            headingRowHeight: 38,
                            dataRowMinHeight: 34,
                            dataRowMaxHeight: 44,
                            columns: const [
                              DataColumn(label: Text('PID')),
                              DataColumn(label: Text('名称')),
                              DataColumn(label: Text('状态')),
                              DataColumn(label: Text('内存')),
                              DataColumn(label: Text('CPU 时间')),
                              DataColumn(label: Text('命令')),
                            ],
                            rows: [
                              for (final process in _filtered)
                                DataRow(
                                  cells: [
                                    DataCell(
                                      Text('${process.pid}', style: monospace),
                                    ),
                                    DataCell(
                                      Text(
                                        process.name,
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                    DataCell(
                                      StatusPill(
                                        text: process.state,
                                        good: process.state == 'running',
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        formatBytes(process.rssBytes),
                                        style: monospace,
                                      ),
                                    ),
                                    DataCell(
                                      Text(
                                        _cpuTime(process.cpuTicks),
                                        style: monospace,
                                      ),
                                    ),
                                    DataCell(
                                      ConstrainedBox(
                                        constraints: const BoxConstraints(
                                          maxWidth: 520,
                                        ),
                                        child: Text(
                                          process.command,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: hampanelMuted,
                                          ),
                                        ),
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

  String _cpuTime(int ticks) {
    final seconds = ticks ~/ 100;
    final minutes = seconds ~/ 60;
    final hours = minutes ~/ 60;
    if (hours > 0) return '${hours}h ${minutes % 60}m';
    if (minutes > 0) return '${minutes}m ${seconds % 60}s';
    return '${seconds}s';
  }
}
