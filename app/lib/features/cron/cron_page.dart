import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/cron.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class CronPage extends StatefulWidget {
  const CronPage({super.key});

  @override
  State<CronPage> createState() => _CronPageState();
}

class _CronPageState extends State<CronPage> {
  List<CronEntry> _entries = const [];
  String? _error;
  bool _loading = true;

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
      final json = await _api.getJson('/api/v1/cron');
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _entries = ((map['entries'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CronEntry.fromJson)
            .toList();
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

  Future<void> _add() async {
    final scheduleController = TextEditingController(text: '0 3 * * *');
    final commandController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增计划任务'),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: scheduleController,
                style: monospace,
                decoration: const InputDecoration(
                  labelText: 'Cron 表达式',
                  hintText: '0 3 * * * 或 @daily',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: commandController,
                style: monospace,
                decoration: const InputDecoration(
                  labelText: '命令',
                  hintText: '/usr/local/bin/backup.sh',
                ),
              ),
              const SizedBox(height: 10),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Linux 写入面板托管的 root crontab 区块；Windows 映射为任务计划程序。',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('创建'),
          ),
        ],
      ),
    );

    if (submitted == true) {
      try {
        await _api.postJson('/api/v1/cron', {
          'schedule': scheduleController.text.trim(),
          'command': commandController.text.trim(),
        });
        await _load();
      } catch (error) {
        _toast(describeError(error));
      }
    }
    scheduleController.dispose();
    commandController.dispose();
  }

  Future<void> _delete(CronEntry entry) async {
    final ok = await confirmDialog(
      context,
      title: '删除计划任务?',
      message: entry.command,
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.postJson('/api/v1/cron/delete', {'id': entry.id});
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
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
          title: '计划任务',
          subtitle: '${_entries.length} 个由面板托管的任务',
          actions: [
            OutlinedButton.icon(
              onPressed: _add,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增任务'),
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
              : _entries.isEmpty
              ? EmptyState(
                  icon: Icons.schedule_outlined,
                  title: '没有计划任务',
                  message: '创建的任务会被标记，便于与系统现有任务区分。',
                  action: FilledButton(
                    onPressed: _add,
                    child: const Text('新增任务'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final entry = _entries[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: hampanelAccent.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                entry.schedule,
                                style: monospace.copyWith(
                                  fontSize: 12,
                                  color: hampanelAccent,
                                ),
                              ),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Text(
                                entry.command,
                                overflow: TextOverflow.ellipsis,
                                style: monospace,
                              ),
                            ),
                            IconButton(
                              tooltip: '删除',
                              onPressed: () => _delete(entry),
                              icon: const Icon(Icons.delete_outline, size: 18),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}
