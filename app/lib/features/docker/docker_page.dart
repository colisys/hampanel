import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class DockerPage extends StatefulWidget {
  const DockerPage({super.key});

  @override
  State<DockerPage> createState() => _DockerPageState();
}

class _DockerPageState extends State<DockerPage> {
  List<DockerContainer> _containers = const [];
  List<DockerImage> _images = const [];
  String? _error;
  bool _loading = true;

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
      final results = await Future.wait([
        _api.getJson('/api/v1/docker/containers'),
        _api.getJson('/api/v1/docker/images'),
      ]);
      final containerJson = results[0] as Map<String, dynamic>;
      final imageJson = results[1] as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _containers =
            ((containerJson['containers'] as List<dynamic>?) ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(DockerContainer.fromJson)
                .toList();
        _images = ((imageJson['images'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerImage.fromJson)
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

  Future<void> _action(DockerContainer container, String action) async {
    if (action == 'rm') {
      final ok = await confirmDialog(
        context,
        title: '删除容器 ${container.name}?',
        message: '容器会被强制删除，数据卷仍然保留。',
        confirmLabel: '删除',
        danger: true,
      );
      if (!ok) return;
    }
    try {
      final json = await _api.postJson(
        '/api/v1/docker/containers/${container.id}/$action',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final output = (map['output'] as String? ?? '').trim();
      if (output.isNotEmpty) _toast(output);
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _logs(DockerContainer container) async {
    try {
      final json = await _api.getJson(
        '/api/v1/docker/containers/${container.id}/logs',
        query: {'lines': '300'},
      );
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('${container.name} 日志'),
          content: SizedBox(
            width: 860,
            height: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                (map['output'] as String? ?? '').isEmpty
                    ? '暂无日志'
                    : map['output'] as String,
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
          title: '容器',
          subtitle: '${_containers.length} 个容器 · ${_images.length} 个镜像',
          actions: [
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
              : DefaultTabController(
                  length: 2,
                  child: Column(
                    children: [
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TabBar(
                            isScrollable: true,
                            tabAlignment: TabAlignment.start,
                            tabs: [
                              Tab(text: '容器'),
                              Tab(text: '镜像'),
                            ],
                          ),
                        ),
                      ),
                      Expanded(
                        child: TabBarView(
                          children: [_containersTab(), _imagesTab()],
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ],
    );
  }

  Widget _containersTab() {
    if (_containers.isEmpty) {
      return EmptyState(
        icon: Icons.widgets_outlined,
        title: '没有容器',
        message: 'Docker 中还没有容器。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      itemCount: _containers.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final container = _containers[index];
        final running = container.state == 'running';
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: running ? hampanelAccent : hampanelMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        container.name,
                        style: const TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        container.image,
                        style: TextStyle(
                          fontSize: 11,
                          color: hampanelMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 3,
                  child: Text(
                    container.status,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                    ),
                  ),
                ),
                SizedBox(
                  width: 190,
                  child: Text(
                    container.ports,
                    overflow: TextOverflow.ellipsis,
                    style: monospace.copyWith(fontSize: 11),
                  ),
                ),
                StatusPill(text: container.state, good: running),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '日志',
                  onPressed: () => _logs(container),
                  icon: const Icon(Icons.receipt_long_outlined, size: 17),
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (value) => _action(container, value),
                  itemBuilder: (context) => [
                    if (!running)
                      const PopupMenuItem(value: 'start', child: Text('启动')),
                    if (running)
                      const PopupMenuItem(value: 'stop', child: Text('停止')),
                    if (running)
                      const PopupMenuItem(value: 'pause', child: Text('暂停')),
                    if (!running)
                      const PopupMenuItem(value: 'unpause', child: Text('恢复')),
                    const PopupMenuItem(value: 'restart', child: Text('重启')),
                    PopupMenuItem(value: 'rm', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _imagesTab() {
    if (_images.isEmpty) {
      return EmptyState(
        icon: Icons.layers_outlined,
        title: '没有镜像',
        message: 'Docker 中还没有镜像。',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
      itemCount: _images.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        final image = _images[index];
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Icon(
                  Icons.layers_outlined,
                  size: 20,
                  color: hampanelMuted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    '${image.repository}:${image.tag}',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                SizedBox(
                  width: 180,
                  child: Text(
                    image.id,
                    overflow: TextOverflow.ellipsis,
                    style: monospace,
                  ),
                ),
                SizedBox(
                  width: 90,
                  child: Text(
                    image.size,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                    ),
                  ),
                ),
                SizedBox(
                  width: 110,
                  child: Text(
                    image.createdAt,
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
