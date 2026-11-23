import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/cron.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'cron_builder.dart';

class CronPage extends StatefulWidget {
  const CronPage({super.key});

  @override
  State<CronPage> createState() => _CronPageState();
}

class _CronPageState extends State<CronPage> {
  List<CronEntry> _entries = const [];
  List<CronPanelJob> _panelJobs = const [];
  String? _error;
  bool _loading = true;

  /// "panel" or "user"; groups the list so curated daemon jobs are never
  /// mistaken for the operator's own crontab.
  String _filter = 'all';

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
        _panelJobs = ((map['panelJobs'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(CronPanelJob.fromJson)
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
    final kind = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增计划任务'),
        content: DialogBody(
          maxWidth: 460,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                leading: const Icon(Icons.dashboard_customize_outlined),
                title: const Text('面板任务'),
                subtitle: const Text('选择证书、软件服务或维护检查'),
                onTap: () => Navigator.pop(context, 'panel'),
              ),
              const Divider(height: 1),
              ListTile(
                leading: const Icon(Icons.terminal_outlined),
                title: const Text('普通任务'),
                subtitle: const Text('自定义 crontab 命令'),
                onTap: () => Navigator.pop(context, 'user'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
        ],
      ),
    );
    if (kind == null) return;
    if (kind == 'panel') {
      await _addPanelJob();
    } else {
      await _addUserJob();
    }
  }

  Future<void> _addPanelJob() async {
    if (_panelJobs.isEmpty) {
      _toast('当前平台或 daemon 未提供面板任务');
      return;
    }
    final jobs = _panelJobs;
    var job = jobs.first;
    String groupOf(CronPanelJob job) => job.group ?? '内置任务';
    final groups = jobs.map(groupOf).toSet();
    var schedule = '0 3 * * *';
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('新增面板任务'),
          content: DialogBody(
            maxWidth: 680,
            maxHeight: 620,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: groupOf(job),
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '任务类型'),
                    items: [
                      for (final group in groups)
                        DropdownMenuItem(value: group, child: Text(group)),
                    ],
                    onChanged: (value) => update(
                      () => job = jobs.firstWhere((j) => groupOf(j) == value),
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(groupOf(job)),
                    initialValue: job.id,
                    isExpanded: true,
                    decoration: const InputDecoration(labelText: '执行目标'),
                    items: [
                      for (final j in jobs.where(
                        (j) => groupOf(j) == groupOf(job),
                      ))
                        DropdownMenuItem(value: j.id, child: Text(j.label)),
                    ],
                    onChanged: (id) =>
                        update(() => job = jobs.firstWhere((j) => j.id == id)),
                  ),
                  const SizedBox(height: 12),
                  CronBuilder(
                    initial: schedule,
                    onChanged: (value) => schedule = value,
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '面板任务只能执行内置命令，不接受自定义 shell。',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ],
              ),
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
      ),
    );
    if (submitted != true) return;
    try {
      await _api.postJson('/api/v1/cron', {
        'schedule': schedule.trim(),
        if (job.group == null) 'command': job.command else 'jobId': job.id,
        'kind': 'panel',
      });
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _addUserJob() async {
    var schedule = '0 3 * * *';
    final commandController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('新增普通任务'),
        content: DialogBody(
          maxWidth: 680,
          maxHeight: 620,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                CronBuilder(
                  initial: schedule,
                  onChanged: (value) => schedule = value,
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
                Text(
                  'Linux 写入面板托管的 root crontab 区块；Windows 映射为任务计划程序。',
                  style: TextStyle(fontSize: 11, color: hampanelMuted),
                ),
              ],
            ),
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
          'schedule': schedule.trim(),
          'command': commandController.text.trim(),
          'kind': 'user',
        });
        await _load();
      } catch (error) {
        _toast(describeError(error));
      }
    }
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

  List<CronEntry> get _visible {
    if (_filter == 'panel') {
      return _entries.where((entry) => entry.isPanel).toList();
    }
    if (_filter == 'user') {
      return _entries.where((entry) => !entry.isPanel).toList();
    }
    return _entries;
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final visible = _visible;
    return Column(
      children: [
        PageHeader(
          title: '计划任务',
          subtitle:
              '${_entries.where((entry) => entry.isPanel).length} 个面板任务'
              ' · ${_entries.where((entry) => !entry.isPanel).length} 个普通任务',
          actions: [
            if (!compact) ...[
              OutlinedButton.icon(
                onPressed: _add,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('新增任务'),
              ),
              const SizedBox(width: 8),
            ],
            PageRefreshButton(onPressed: _load, refreshing: _loading),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Padding(
          padding: pageContentPadding(context, top: 0),
          child: LayoutBuilder(
            builder: (context, constraints) => SizedBox(
              width: constraints.maxWidth,
              child: SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'all', label: Text('全部')),
                  ButtonSegment(value: 'panel', label: Text('面板任务')),
                  ButtonSegment(value: 'user', label: Text('普通任务')),
                ],
                selected: {_filter},
                onSelectionChanged: (value) =>
                    setState(() => _filter = value.first),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loading
              ? const LoadingView()
              : visible.isEmpty
              ? EmptyState(
                  icon: Icons.schedule_outlined,
                  title: '没有计划任务',
                  message: _entries.isEmpty
                      ? '创建的任务会被标记，便于与系统现有任务区分。'
                      : '当前分类下没有任务。',
                  action: FilledButton(
                    onPressed: _add,
                    child: const Text('新增任务'),
                  ),
                )
              : ListView.separated(
                  padding: pageContentPadding(context),
                  itemCount: visible.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final entry = visible[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: hampanelAccent.withValues(alpha: 0.10),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                entry.schedule,
                                style: monospace.copyWith(
                                  fontSize: 12,
                                  color: hampanelAccent,
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                StatusPill(
                                  text: entry.isPanel ? '面板任务' : '普通任务',
                                  good: entry.isPanel,
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    entry.command,
                                    style: monospace,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
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
        if (compact)
          ActionDock(
            actions: [
              ActionDockItem(icon: Icons.add, label: '新增任务', onPressed: _add),
            ],
          ),
      ],
    );
  }
}
