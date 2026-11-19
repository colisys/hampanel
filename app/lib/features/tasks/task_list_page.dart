import 'dart:async';
import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/session.dart';
import '../../core/task_center.dart';
import '../../ui/log_page.dart';
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
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => LogPage(
              title: task.title.isEmpty ? task.kind : task.title,
              emptyMessage: '等待输出…',
              stream: () => _taskOutputStream(center, task.id),
            ),
          ),
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

/// Converts the task SSE stream into plain output chunks for [LogPage].
Stream<String> _taskOutputStream(TaskCenter center, String id) async* {
  final response = await center.api.openEventStream('/api/v1/tasks/$id/events');
  String? event;
  final data = StringBuffer();
  await for (final line
      in response.transform(utf8.decoder).transform(const LineSplitter())) {
    if (line.isEmpty) {
      if (event == 'output' && data.isNotEmpty) {
        try {
          final json = jsonDecode(data.toString());
          if (json is Map<String, dynamic>) {
            final bytes = base64Decode(json['data'] as String? ?? '');
            final text = utf8.decode(bytes, allowMalformed: true);
            if (text.isNotEmpty) yield text;
          }
        } catch (_) {
          // ignore malformed frames
        }
      }
      event = null;
      data.clear();
      continue;
    }
    if (line.startsWith('event:')) {
      event = line.substring(6).trim();
    } else if (line.startsWith('data:')) {
      if (data.isNotEmpty) data.write('\n');
      data.write(line.substring(5).trim());
    }
  }
}
