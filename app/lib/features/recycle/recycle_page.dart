import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models/recycle_entry.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';

class RecyclePage extends StatefulWidget {
  const RecyclePage({super.key});

  @override
  State<RecyclePage> createState() => _RecyclePageState();
}

class _RecyclePageState extends State<RecyclePage> {
  List<RecycleEntry> _entries = const [];
  bool _loading = true;
  String? _error;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/recycle');
      final map = json as Map<String, dynamic>;
      final entries = ((map['entries'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(RecycleEntry.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _entries = entries;
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

  Future<void> _restore(RecycleEntry entry) async {
    final ok = await confirmDialog(
      context,
      title: '恢复 ${entry.name}？',
      message: '将恢复到原路径：${entry.originalPath}\n如果原路径已存在，恢复会失败。',
      confirmLabel: '恢复',
    );
    if (!ok) return;
    await _run('/api/v1/recycle/restore', {'id': entry.id}, '已恢复');
  }

  Future<void> _purge(RecycleEntry entry) async {
    final ok = await confirmDialog(
      context,
      title: '永久删除 ${entry.name}？',
      message: '该操作不可恢复，会直接删除回收站中的内容。',
      confirmLabel: '永久删除',
      danger: true,
    );
    if (!ok) return;
    await _run('/api/v1/recycle/delete', {'id': entry.id}, '已永久删除');
  }

  Future<void> _empty() async {
    final ok = await confirmDialog(
      context,
      title: '清空回收站？',
      message: '回收站中的所有文件与目录将被永久删除，无法恢复。',
      confirmLabel: '清空',
      danger: true,
    );
    if (!ok) return;
    await _run('/api/v1/recycle/empty', const {}, '回收站已清空');
  }

  Future<void> _run(
    String path,
    Map<String, dynamic> body,
    String success,
  ) async {
    try {
      final json = await _api.postJson(path, body);
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(context, '操作失败', map['output'] as String? ?? '');
      } else {
        _toast(success);
      }
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
          title: '回收站',
          subtitle: '通过面板删除的文件与目录会先移动到面板数据目录',
          actions: [
            OutlinedButton.icon(
              onPressed: _entries.isEmpty ? null : _empty,
              icon: const Icon(Icons.delete_sweep_outlined, size: 16),
              label: const Text('清空回收站'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        Expanded(
          child: _loading
              ? LoadingView()
              : _error != null
              ? SingleChildScrollView(
                  child: ErrorBanner(message: _error!, onRetry: _load),
                )
              : _entries.isEmpty
              ? EmptyState(
                  icon: Icons.delete_outline,
                  title: '回收站为空',
                  message: '从「文件」页面删除的内容会出现在这里，可恢复或永久删除。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _card(_entries[index]),
                ),
        ),
      ],
    );
  }

  Widget _card(RecycleEntry entry) {
    final isDir = entry.kind == 'dir';
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Icon(
              isDir ? Icons.folder_outlined : Icons.description_outlined,
              size: 20,
              color: isDir ? hampanelAccent : hampanelMuted,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        entry.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 8),
                      StatusPill(text: isDir ? '目录' : '文件', good: isDir),
                      const SizedBox(width: 8),
                      Text(
                        isDir ? '-' : formatBytes(entry.size),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.originalPath,
                    style: monospace.copyWith(
                      fontSize: 11.5,
                      color: hampanelMuted,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '删除于 ${formatDateTime(entry.deletedAt)}',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _restore(entry),
              icon: const Icon(Icons.restore, size: 16),
              label: const Text('恢复'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '永久删除',
              onPressed: () => _purge(entry),
              icon: Icon(
                Icons.delete_forever_outlined,
                size: 19,
                color: hampanelDanger,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
