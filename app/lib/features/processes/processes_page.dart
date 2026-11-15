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
  int? _busyPid;

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

  Future<void> _showDetail(ProcessInfo process) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ProcessDetailDialog(pid: process.pid),
    );
  }

  Future<void> _terminate(ProcessInfo process, String signal) async {
    final confirmed = await confirmDialog(
      context,
      title: signal == 'KILL' ? '强制结束进程' : '结束进程',
      message:
          '${signal == 'KILL' ? '强制终止' : '结束'} ${process.name}（PID ${process.pid}）？'
          '${signal == 'KILL' ? '\n进程无法清理临时数据。' : ''}',
      confirmLabel: '结束',
      danger: true,
    );
    if (confirmed != true) return;
    if (!mounted) return;
    final api = PanelScope.of(context).api;
    setState(() => _busyPid = process.pid);
    try {
      await api.postJson('/api/v1/processes/${process.pid}/kill', {
        'signal': signal,
      });
      _toast('已向 PID ${process.pid} 发送 $signal 信号');
      await _load();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busyPid = null);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
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
                              DataColumn(label: Text('操作')),
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
                                    DataCell(
                                      _busyPid == process.pid
                                          ? const SizedBox(
                                              width: 18,
                                              height: 18,
                                              child: CircularProgressIndicator(
                                                strokeWidth: 2,
                                              ),
                                            )
                                          : PopupMenuButton<String>(
                                              tooltip: '进程操作',
                                              onSelected: (value) {
                                                if (value == 'detail') {
                                                  _showDetail(process);
                                                } else if (value == 'term') {
                                                  _terminate(process, 'TERM');
                                                } else if (value == 'kill') {
                                                  _terminate(process, 'KILL');
                                                }
                                              },
                                              itemBuilder: (context) => const [
                                                PopupMenuItem(
                                                  value: 'detail',
                                                  child: Text('详情'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'term',
                                                  child: Text('结束进程 (TERM)'),
                                                ),
                                                PopupMenuItem(
                                                  value: 'kill',
                                                  child: Text('强制结束 (KILL)'),
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

  String _cpuTime(int ticks) {
    final seconds = ticks ~/ 100;
    final minutes = seconds ~/ 60;
    final hours = minutes ~/ 60;
    if (hours > 0) return '${hours}h ${minutes % 60}m';
    if (minutes > 0) return '${minutes}m ${seconds % 60}s';
    return '${seconds}s';
  }
}

class _ProcessDetailDialog extends StatefulWidget {
  const _ProcessDetailDialog({required this.pid});

  final int pid;

  @override
  State<_ProcessDetailDialog> createState() => _ProcessDetailDialogState();
}

class _ProcessDetailDialogState extends State<_ProcessDetailDialog> {
  ProcessDetail? _detail;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final json = await PanelScope.of(context).api
          .getJson('/api/v1/processes/${widget.pid}');
      if (!mounted) return;
      setState(() {
        _detail = ProcessDetail.fromJson(json as Map<String, dynamic>);
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    }
  }

  @override
  Widget build(BuildContext context) {
    final detail = _detail;
    return AlertDialog(
      title: Text('进程详情 · PID ${widget.pid}'),
      content: DialogBody(
        maxWidth: 880,
        maxHeight: 560,
        child: _error != null
            ? ErrorBanner(message: _error!, onRetry: _load)
            : detail == null
            ? const LoadingView()
            : SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _row('名称', detail.name),
                    _row('状态', detail.state),
                    _row('父进程', '${detail.ppid}'),
                    _row('用户 / 组', '${detail.uid} / ${detail.gid}'),
                    _row('线程数', '${detail.threads}'),
                    _row('内存占用', formatBytes(detail.rssBytes)),
                    _row('CPU 时间', _formatTicks(detail.cpuTicks)),
                    _row('可执行文件', detail.exe.isEmpty ? '-' : detail.exe),
                    _row('工作目录', detail.cwd.isEmpty ? '-' : detail.cwd),
                    _row('命令行', detail.command),
                    const SizedBox(height: 10),
                    Text(
                      '监听 / 打开的端口',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    if (detail.ports.isEmpty)
                      Text(
                        '未发现关联端口',
                        style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                      )
                    else
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final port in detail.ports)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: hampanelBorder),
                              ),
                              child: Text(
                                '${port.protocol} ${port.localPort} · ${port.state}',
                                style: monospace.copyWith(fontSize: 11),
                              ),
                            ),
                        ],
                      ),
                    const SizedBox(height: 12),
                    Text(
                      '打开的文件（${detail.openFiles.length}）',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      height: 160,
                      width: double.infinity,
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: hampanelSurfaceAlt,
                        border: Border.all(color: hampanelBorder),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          detail.openFiles.isEmpty
                              ? '无法读取打开的文件'
                              : detail.openFiles.take(120).join('\n'),
                          style: monospace.copyWith(fontSize: 11),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }

  String _formatTicks(int ticks) {
    final seconds = ticks ~/ 100;
    final minutes = seconds ~/ 60;
    final hours = minutes ~/ 60;
    if (hours > 0) return '${hours}h ${minutes % 60}m';
    if (minutes > 0) return '${minutes}m ${seconds % 60}s';
    return '${seconds}s';
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace.copyWith(fontSize: 11.5, color: hampanelInkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
