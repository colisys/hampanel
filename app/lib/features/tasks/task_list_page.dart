import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/task_center.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class TaskListPage extends StatelessWidget {
  const TaskListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final center = PanelScope.of(context).tasks;
    return AnimatedBuilder(
      animation: center,
      builder: (context, _) {
        final items = center.tasks;
        return Column(
          children: [
            PageHeader(
              title: '任务',
              subtitle: '服务端异步执行；断开连接后任务继续运行',
              actions: [
                if (!center.online)
                  const StatusPill(text: '重连中', good: false),
              ],
            ),
            Expanded(
              child: items.isEmpty
                  ? Center(
                      child: Text('暂无任务', style: TextStyle(color: hampanelMuted)),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                      itemCount: items.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 8),
                      itemBuilder: (context, index) =>
                          _TaskCard(center: center, task: items[index]),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.center, required this.task});

  final TaskCenter center;
  final TaskSummary task;

  @override
  Widget build(BuildContext context) {
    final progress = task.progress;
    return PanelCard(
      padding: const EdgeInsets.fromLTRB(14, 12, 10, 12),
      child: InkWell(
        onTap: () => showDialog<void>(
          context: context,
          builder: (_) => _TaskDetailDialog(center: center, task: task),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    task.title.isEmpty ? task.kind : task.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13.5),
                  ),
                ),
                StatusPill(text: task.statusLabel, good: task.status == 'succeeded'),
                PopupMenuButton<String>(
                  tooltip: '任务操作',
                  onSelected: (action) async {
                    try {
                      if (action == 'cancel') {
                        await center.cancel(task.id);
                      } else {
                        await center.dismiss(task.id);
                      }
                    } catch (error) {
                      if (context.mounted) showAppSnackBar(context, SnackBar(content: Text(describeError(error))));
                    }
                  },
                  itemBuilder: (_) => [
                    if (task.active) const PopupMenuItem(value: 'cancel', child: Text('取消任务')),
                    if (!task.active) const PopupMenuItem(value: 'dismiss', child: Text('移除记录')),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${task.kind}${task.phase.isEmpty ? '' : ' · ${task.phase}'}'
              '${task.updatedAt == null ? '' : ' · ${formatTimestamp(task.updatedAt)}'}',
              style: TextStyle(fontSize: 11, color: hampanelMuted),
            ),
            if (task.active) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: progress == null ? null : progress / 100.0, minHeight: 2),
            ],
          ],
        ),
      ),
    );
  }
}

class _TaskDetailDialog extends StatefulWidget {
  const _TaskDetailDialog({required this.center, required this.task});

  final TaskCenter center;
  final TaskSummary task;

  @override
  State<_TaskDetailDialog> createState() => _TaskDetailDialogState();
}

class _TaskDetailDialogState extends State<_TaskDetailDialog> {
  final StringBuffer _output = StringBuffer();
  final ScrollController _scroll = ScrollController();
  StreamSubscription<String>? _subscription;
  late String _status = widget.task.status;
  late String _phase = widget.task.phase;
  String _error = '';
  bool _done = false;

  @override
  void initState() {
    super.initState();
    _open();
  }

  Future<void> _open() async {
    try {
      final response = await widget.center.api.openEventStream('/api/v1/tasks/${widget.task.id}/events');
      String? event;
      final data = StringBuffer();
      _subscription = response.transform(utf8.decoder).transform(const LineSplitter()).listen(
        (line) {
          if (line.isEmpty) {
            if (event != null) _handle(event!, data.toString());
            event = null;
            data.clear();
            return;
          }
          if (line.startsWith('event:')) {
            event = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (data.isNotEmpty) data.write('\n');
            data.write(line.substring(5).trim());
          }
        },
        onError: (_) {},
      );
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    }
  }

  void _handle(String event, String data) {
    if (!mounted || data.isEmpty) return;
    final json = jsonDecode(data);
    if (json is! Map<String, dynamic>) return;
    if (event == 'output') {
      try {
        final bytes = base64Decode(json['data'] as String? ?? '');
        _append(utf8.decode(bytes, allowMalformed: true));
      } on FormatException {
        // ignore malformed output frame
      }
      return;
    }
    if (event == 'status') {
      setState(() {
        _status = json['status'] as String? ?? _status;
        _phase = json['phase'] as String? ?? _phase;
        _error = json['error'] as String? ?? '';
        _done = !(_status == 'queued' || _status == 'running' || _status == 'canceling');
      });
    }
    if (event == 'reset') {
      _output.clear();
      setState(() {});
      return;
    }
    if (event == 'gone') setState(() => _done = true);
  }

  void _append(String text) {
    _output.write(text);
    if (_output.length > 512 * 1024) {
      final value = _output.toString();
      _output
        ..clear()
        ..write(value.substring(value.length - 384 * 1024));
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final label = switch (_status) {
      'succeeded' => '已完成',
      'failed' => '失败',
      'canceled' => '已取消',
      'interrupted' => '已中断',
      'running' => '运行中',
      'queued' => '排队中',
      _ => _status,
    };
    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(
              widget.task.title.isEmpty ? widget.task.kind : widget.task.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          StatusPill(text: label, good: _status == 'succeeded'),
        ],
      ),
      content: DialogBody(
        maxWidth: 760,
        maxHeight: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              '${widget.task.kind}${_phase.isEmpty ? '' : ' · $_phase'}',
              style: TextStyle(fontSize: 11, color: hampanelMuted),
            ),
            if (_error.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(_error, style: TextStyle(fontSize: 11, color: hampanelDanger)),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                padding: const EdgeInsets.all(10),
                color: hampanelInk,
                child: SingleChildScrollView(
                  controller: _scroll,
                  child: SelectableText(
                    _output.isEmpty ? '等待输出…' : _output.toString(),
                    style: TextStyle(
                      fontFamily: 'FiraCode',
                      fontFamilyFallback: ['DejaVu Sans Mono', 'monospace'],
                      fontSize: 12,
                      height: 1.45,
                      color: hampanelSurface,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (!_done)
          TextButton(
            onPressed: () async {
              try {
                await widget.center.cancel(widget.task.id);
              } catch (error) {
                if (context.mounted) showAppSnackBar(context, SnackBar(content: Text(describeError(error))));
              }
            },
            child: const Text('取消任务'),
          ),
        FilledButton(onPressed: () => Navigator.of(context).pop(), child: const Text('关闭')),
      ],
    );
  }
}
