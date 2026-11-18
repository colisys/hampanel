import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/widgets.dart';

class VolumesSection extends StatefulWidget {
  const VolumesSection({super.key});

  @override
  State<VolumesSection> createState() => _VolumesSectionState();
}

class _VolumesSectionState extends State<VolumesSection> {
  List<DockerVolume> _volumes = const [];
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
      final json = await _api.getJson('/api/v1/docker/volumes');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _volumes = ((map['volumes'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerVolume.fromJson)
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

  Future<void> _create() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => _VolumeDialog(api: _api),
    );
    if (created == true) {
      _toast('存储卷已创建');
      await _load();
    }
  }

  Future<void> _delete(DockerVolume volume) async {
    final ok = await confirmDialog(
      context,
      title: '删除存储卷 ${volume.name}?',
      message: '正在被容器使用的卷会阻止删除；删除后数据无法恢复。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.deleteJson(
        '/api/v1/docker/volumes/${Uri.encodeComponent(volume.name)}',
      );
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _prune() async {
    final ok = await confirmDialog(
      context,
      title: '清理未使用存储卷?',
      message: '会删除没有被容器使用的卷，数据无法恢复。',
      confirmLabel: '清理',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.postJson('/api/v1/docker/volumes/prune', const {});
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
          title: '存储卷',
          subtitle: '${_volumes.length} 个存储卷',
          actions: [
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('创建存储卷'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _prune,
              icon: const Icon(Icons.cleaning_services_outlined, size: 16),
              label: const Text('清理'),
            ),
            PageRefreshButton(onPressed: _load),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _volumes.isEmpty
              ? const EmptyState(
                  icon: Icons.save_outlined,
                  title: '没有存储卷',
                  message: '还没有创建或使用存储卷。',
                )
              : ListView.separated(
                  padding: pageContentPadding(context, top: 8),
                  itemCount: _volumes.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final volume = _volumes[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.save_outlined,
                              size: 20,
                              color: hampanelMuted,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        volume.name,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        '${volume.driver} · ${volume.scope}',
                                        style: TextStyle(
                                          fontSize: 10.5,
                                          color: hampanelMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    volume.mountpoint.isEmpty
                                        ? '—'
                                        : volume.mountpoint,
                                    overflow: TextOverflow.ellipsis,
                                    style: monospace.copyWith(fontSize: 10.5),
                                  ),
                                  if (volume.options.isNotEmpty)
                                    Text(
                                      volume.options.join(' · '),
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: hampanelMuted,
                                      ),
                                    ),
                                  if (volume.labels.isNotEmpty)
                                    Text(
                                      volume.labels.join(', '),
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: hampanelMuted,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            Text(
                              formatTimestamp(volume.createdAt),
                              style: TextStyle(
                                fontSize: 10.5,
                                color: hampanelMuted,
                              ),
                            ),
                            IconButton(
                              tooltip: '删除',
                              onPressed: () => _delete(volume),
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

class _VolumeDialog extends StatefulWidget {
  const _VolumeDialog({required this.api});

  final ApiClient api;

  @override
  State<_VolumeDialog> createState() => _VolumeDialogState();
}

class _VolumeDialogState extends State<_VolumeDialog> {
  final _name = TextEditingController();
  final _driver = TextEditingController(text: 'local');
  final _options = TextEditingController();
  final _labels = TextEditingController();
  bool _saving = false;
  String? _error;

  ApiClient get _api => widget.api;

  @override
  void dispose() {
    _name.dispose();
    _driver.dispose();
    _options.dispose();
    _labels.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty) {
      setState(() => _error = '卷名称不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _api.postJson('/api/v1/docker/volumes', {
        'name': _name.text.trim(),
        'driver': _driver.text.trim().isEmpty ? 'local' : _driver.text.trim(),
        'options': _lines(_options.text),
        'labels': _lines(_labels.text),
      });
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('创建存储卷'),
      content: DialogBody(
        maxWidth: 480,
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _driver,
                decoration: const InputDecoration(labelText: '驱动'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _options,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '驱动选项（每行 KEY=VALUE）',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _labels,
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '标签（每行 KEY=VALUE）',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: hampanelDanger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '创建'),
        ),
      ],
    );
  }
}

List<String> _lines(String value) => value
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList();
