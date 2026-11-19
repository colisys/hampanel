import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/log_viewer.dart';
import '../../ui/widgets.dart';
import '../../ui/remote_picker.dart';
import 'container_detail_page.dart';
import 'container_files_dialog.dart';
import 'container_terminal_dialog.dart';

class ContainersSection extends StatefulWidget {
  const ContainersSection({super.key, this.engine});

  final String? engine;

  @override
  State<ContainersSection> createState() => _ContainersSectionState();
}

class _ContainersSectionState extends State<ContainersSection> {
  List<DockerContainer> _containers = const [];
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
      final json = await _api.getJson(
        '/api/v1/docker/containers',
        query: const {'stats': '1'},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _containers = ((map['containers'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerContainer.fromJson)
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

  Future<void> _create() async {
    final created = await showDialog<bool>(
      context: context,
      builder: (context) => ContainerEditorDialog(api: _api),
    );
    if (created == true) {
      _toast('容器已创建');
      await _load();
    }
  }

  Future<void> _openDetail(DockerContainer container) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ContainerDetailPage(
          api: _api,
          containerId: container.id,
          initial: container,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Future<void> _note(DockerContainer container) async {
    final note = await textInputDialog(
      context,
      title: '备注 · ${container.name}',
      label: '备注',
      initial: container.note,
      multiline: true,
    );
    if (note == null) return;
    try {
      await _api.putJson(
        '/api/v1/docker/notes/${container.name}',
        <String, dynamic>{'note': note},
      );
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _commit(DockerContainer container) async {
    final reference = await showDialog<({String repository, String tag})>(
      context: context,
      builder: (context) => const _CommitDialog(),
    );
    if (reference == null) return;
    try {
      final json = await _api.postJson(
        '/api/v1/docker/containers/${container.id}/commit',
        <String, dynamic>{
          'repository': reference.repository,
          'tag': reference.tag,
        },
      );
      final map = json as Map<String, dynamic>? ?? const {};
      _toast('已提交镜像 ${map['image'] ?? ''}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _logs(DockerContainer container) async {
    try {
      final json = await _api.getJson(
        '/api/v1/docker/containers/${container.id}/logs',
        query: const {'lines': '500'},
      );
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      await showLogViewerDialog(
        context,
        title: '${container.name} 日志',
        content: map['output'] as String? ?? '',
        emptyMessage: '暂无日志',
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _terminal(DockerContainer container) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          ContainerTerminalDialog(api: _api, container: container),
    );
  }

  Future<void> _files(DockerContainer container) async {
    await showDialog<void>(
      context: context,
      builder: (context) =>
          ContainerFilesDialog(api: _api, container: container),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppSnackBar(context, SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '容器列表',
          subtitle:
              '${_containers.length} 个容器'
              '${widget.engine == null ? '' : ' · ${widget.engine}'}',
          actions: [
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('创建容器'),
            ),
            const SizedBox(width: 8),
            PageRefreshButton(onPressed: _load),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _containers.isEmpty
              ? EmptyState(
                  icon: Icons.widgets_outlined,
                  title: '没有容器',
                  message: '从镜像创建一个容器，或先拉取镜像。',
                  action: FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('创建容器'),
                  ),
                )
              : ListView.separated(
                  padding: pageContentPadding(context, top: 8),
                  itemCount: _containers.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final container = _containers[index];
                    return _ContainerCard(
                      container: container,
                      onOpen: () => _openDetail(container),
                      onAction: (action) => _action(container, action),
                      onLogs: () => _logs(container),
                      onTerminal: () => _terminal(container),
                      onFiles: () => _files(container),
                      onCommit: () => _commit(container),
                      onNote: () => _note(container),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ContainerCard extends StatelessWidget {
  const _ContainerCard({
    required this.container,
    required this.onOpen,
    required this.onAction,
    required this.onLogs,
    required this.onTerminal,
    required this.onFiles,
    required this.onCommit,
    required this.onNote,
  });

  final DockerContainer container;
  final VoidCallback onOpen;
  final ValueChanged<String> onAction;
  final VoidCallback onLogs;
  final VoidCallback onTerminal;
  final VoidCallback onFiles;
  final VoidCallback onCommit;
  final VoidCallback onNote;

  @override
  Widget build(BuildContext context) {
    final running = container.running;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.inventory_2_outlined,
                  size: 20,
                  color: running ? hampanelAccent : hampanelMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              container.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                          if (container.composeProject.isNotEmpty) ...[
                            const SizedBox(width: 8),
                            Text(
                              container.composeProject,
                              style: TextStyle(
                                fontSize: 10.5,
                                color: hampanelMuted,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        container.image,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11, color: hampanelMuted),
                      ),
                    ],
                  ),
                ),
                StatusPill(text: container.state, good: running),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 18,
              runSpacing: 8,
              children: [
                _Field(label: '网络 / IP', value: container.networkLabel),
                _Field(label: '端口', value: container.portsLabel),
                _Field(label: '资源', value: container.resourceLabel),
                _Field(label: '运行时长', value: container.uptimeLabel),
                _Field(label: '创建时间', value: container.createdLabel),
              ],
            ),
            if (container.note.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                container.note,
                style: TextStyle(
                  fontSize: 11.5,
                  color: hampanelInkSoft,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            // Actions live at the end of the card so the title row stays
            // readable on phones.
            const SizedBox(height: 10),
            Divider(height: 1, color: hampanelBorder),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: onOpen,
                    borderRadius: BorderRadius.circular(2),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Icon(
                            Icons.open_in_new,
                            size: 14,
                            color: hampanelMuted,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '详情',
                            style: TextStyle(
                              fontSize: 12,
                              color: hampanelMuted,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                _CardAction(
                  icon: Icons.terminal,
                  label: '终端',
                  onPressed: running ? onTerminal : null,
                ),
                _CardAction(
                  icon: Icons.receipt_long_outlined,
                  label: '日志',
                  onPressed: onLogs,
                ),
                _CardAction(
                  icon: Icons.folder_open_outlined,
                  label: '文件',
                  onPressed: running ? onFiles : null,
                ),
                PopupMenuButton<String>(
                  icon: const Icon(Icons.more_horiz, size: 18),
                  onSelected: (value) {
                    switch (value) {
                      case 'edit':
                        onOpen();
                      case 'commit':
                        onCommit();
                      case 'note':
                        onNote();
                      default:
                        onAction(value);
                    }
                  },
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
                    const PopupMenuItem(value: 'edit', child: Text('详情与配置')),
                    const PopupMenuItem(value: 'commit', child: Text('导出镜像')),
                    const PopupMenuItem(value: 'note', child: Text('备注')),
                    const PopupMenuItem(value: 'rm', child: Text('删除')),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _CardAction extends StatelessWidget {
  const _CardAction({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return InkWell(
      onTap: onPressed,
      borderRadius: BorderRadius.circular(2),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 6),
        child: Row(
          children: [
            Icon(
              icon,
              size: 15,
              color: enabled ? hampanelInk : hampanelMuted,
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11.5,
                color: enabled ? hampanelInk : hampanelMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(fontSize: 10, color: hampanelMuted)),
        const SizedBox(height: 2),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 260),
          child: Text(
            value,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11.5),
          ),
        ),
      ],
    );
  }
}

class ContainerEditorDialog extends StatefulWidget {
  const ContainerEditorDialog({super.key, required this.api, this.detail});

  final ApiClient api;
  final DockerContainerDetail? detail;

  @override
  State<ContainerEditorDialog> createState() => _ContainerEditorDialogState();
}

class _ContainerEditorDialogState extends State<ContainerEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _image;
  late final TextEditingController _command;
  late final TextEditingController _env;
  late final TextEditingController _ports;
  late final TextEditingController _mounts;
  late final TextEditingController _restart;
  late final TextEditingController _network;
  late final TextEditingController _labels;
  late final TextEditingController _cpus;
  late final TextEditingController _memory;
  String _entrypoint = '';
  bool _saving = false;
  String? _error;

  bool get _editing => widget.detail != null;

  ApiClient get _api => widget.api;

  @override
  void initState() {
    super.initState();
    final detail = widget.detail;
    _name = TextEditingController(text: detail?.name ?? '');
    _image = TextEditingController(text: detail?.image ?? '');
    final command = detail == null
        ? <String>[]
        : [...detail.entrypoint.skip(1), ...detail.command];
    _entrypoint = detail?.entrypoint.isNotEmpty == true
        ? detail!.entrypoint.first
        : '';
    _command = TextEditingController(text: command.join(' '));
    _env = TextEditingController(text: detail?.env.join('\n') ?? '');
    _ports = TextEditingController(
      text: detail?.ports.map((port) => port.label).join('\n') ?? '',
    );
    _mounts = TextEditingController(
      text: detail?.mounts.map((mount) => mount.spec).join('\n') ?? '',
    );
    final restart = detail == null
        ? 'no'
        : detail.restartPolicy == 'on-failure' && detail.restartMax > 0
        ? 'on-failure:${detail.restartMax}'
        : detail.restartPolicy;
    _restart = TextEditingController(text: restart);
    _network = TextEditingController(
      text:
          detail == null ||
              detail.networkMode == 'default' ||
              detail.networkMode == 'bridge'
          ? ''
          : detail.networkMode,
    );
    _labels = TextEditingController(text: detail?.labels.join('\n') ?? '');
    _cpus = TextEditingController(
      text: detail?.cpus == null ? '' : '${detail!.cpus}',
    );
    _memory = TextEditingController(
      text: detail?.memory == null ? '' : '${detail!.memory! ~/ (1024 * 1024)}',
    );
  }

  @override
  void dispose() {
    _name.dispose();
    _image.dispose();
    _command.dispose();
    _env.dispose();
    _ports.dispose();
    _mounts.dispose();
    _restart.dispose();
    _network.dispose();
    _labels.dispose();
    _cpus.dispose();
    _memory.dispose();
    super.dispose();
  }

  Future<void> _appendMount(String source) async {
    final destination = await textInputDialog(
      context,
      title: '挂载到容器的哪个路径？',
      label: '容器内路径',
      initial: '/data',
    );
    if (destination == null || destination.trim().isEmpty) return;
    final line = '$source:${destination.trim()}';
    setState(() {
      _mounts.text = _mounts.text.trim().isEmpty
          ? line
          : '${_mounts.text.trim()}\n$line';
    });
  }

  Future<void> _addHostDirectoryMount() async {
    final picked = await showRemotePicker(
      context,
      source: HostDirectorySource(widget.api),
      confirmLabel: '使用该目录',
    );
    if (picked == null || !mounted) return;
    await _appendMount(picked);
  }

  Future<void> _addVolumeMount() async {
    try {
      final json = await widget.api.getJson('/api/v1/docker/volumes');
      final map = json as Map<String, dynamic>? ?? const {};
      final nodes = ((map['volumes'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(
            (entry) => RemotePickerNode(
              name: entry['name'] as String? ?? '',
              path: entry['name'] as String? ?? '',
              subtitle: entry['mountpoint'] as String? ?? '',
            ),
          )
          .toList();
      if (!mounted) return;
      if (nodes.isEmpty) {
        setState(() => _error = '还没有存储卷，请先在存储卷页面创建');
        return;
      }
      final picked = await showRemotePicker(
        context,
        source: TreePickerSource(title: '选择存储卷', nodes: nodes),
        confirmLabel: '使用该卷',
      );
      if (picked == null || !mounted) return;
      await _appendMount(picked);
    } catch (error) {
      if (mounted) setState(() => _error = describeError(error));
    }
  }

  Future<void> _submit() async {
    if (_name.text.trim().isEmpty || _image.text.trim().isEmpty) {
      setState(() => _error = '名称和镜像不能为空');
      return;
    }
    if (_editing) {
      final ok = await confirmDialog(
        context,
        title: '重建容器 ${_name.text.trim()}?',
        message:
            '容器不可原地修改。保存后会停止旧容器、按新配置重建；'
            '未在表单中保留的运行时参数可能丢失，旧配置会备份在数据目录。',
        confirmLabel: '重建',
        danger: true,
      );
      if (!ok) return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final memoryMb = int.tryParse(_memory.text.trim());
    final body = <String, dynamic>{
      'name': _name.text.trim(),
      'image': _image.text.trim(),
      'command': _splitCommand(_command.text),
      'entrypoint': _entrypoint,
      'env': _lines(_env.text),
      'ports': _lines(_ports.text),
      'mounts': _lines(_mounts.text),
      'restart': _restart.text.trim().isEmpty ? 'no' : _restart.text.trim(),
      'network': _network.text.trim(),
      'labels': _lines(_labels.text),
      if (double.tryParse(_cpus.text.trim()) != null)
        'cpus': double.parse(_cpus.text.trim()),
      if (memoryMb != null) 'memory': memoryMb * 1024 * 1024,
    };
    try {
      if (_editing) {
        await _api.postJson(
          '/api/v1/docker/containers/${widget.detail!.id}/recreate',
          body,
        );
      } else {
        await _api.postJson('/api/v1/docker/containers', body);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.code == 'image_missing'
            ? '本地没有该镜像，请先在镜像管理中拉取。'
            : error.message;
        _saving = false;
      });
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
      title: Text(_editing ? '编辑容器配置' : '创建容器'),
      content: DialogBody(
        maxWidth: 640,
        maxHeight: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_editing)
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    for (final preset in const [
                      'alpine:latest',
                      'busybox:latest',
                      'debian:stable-slim',
                      'ubuntu:latest',
                    ])
                      ActionChip(
                        label: Text(preset),
                        onPressed: () => setState(() {
                          _image.text = preset;
                          if (_name.text.isEmpty) {
                            _name.text = preset.split(':').first;
                          }
                        }),
                      ),
                  ],
                ),
              if (!_editing) const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: '容器名称'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _image,
                decoration: const InputDecoration(
                  labelText: '镜像',
                  hintText: 'nginx:alpine',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _command,
                decoration: const InputDecoration(
                  labelText: '命令（可选）',
                  hintText: 'sh -c "echo hello"',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _env,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '环境变量（每行 KEY=VALUE）',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _ports,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '端口映射（每行 8080:80）',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _mounts,
                minLines: 2,
                maxLines: 6,
                decoration: const InputDecoration(
                  labelText: '挂载（每行 /host:/container 或 volume:/container）',
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  TextButton.icon(
                    onPressed: _addHostDirectoryMount,
                    icon: const Icon(Icons.folder_open_outlined, size: 15),
                    label: const Text('选择主机目录'),
                  ),
                  TextButton.icon(
                    onPressed: _addVolumeMount,
                    icon: const Icon(Icons.save_outlined, size: 15),
                    label: const Text('选择存储卷'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              FormRow(
                children: [
                  TextField(
                    controller: _restart,
                    decoration: const InputDecoration(
                      labelText: '重启策略',
                      hintText: 'no / always / on-failure:3',
                    ),
                  ),
                  TextField(
                    controller: _network,
                    decoration: const InputDecoration(labelText: '网络（可选）'),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _labels,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: '标签（每行 KEY=VALUE）',
                ),
              ),
              const SizedBox(height: 10),
              FormRow(
                children: [
                  TextField(
                    controller: _cpus,
                    decoration: const InputDecoration(
                      labelText: 'CPU 限制（核，可选）',
                    ),
                  ),
                  TextField(
                    controller: _memory,
                    decoration: const InputDecoration(labelText: '内存限制（MB，可选）'),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
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
          onPressed: _saving ? null : _submit,
          child: Text(_saving ? '保存中…' : (_editing ? '重建' : '创建')),
        ),
      ],
    );
  }
}

class _CommitDialog extends StatefulWidget {
  const _CommitDialog();

  @override
  State<_CommitDialog> createState() => _CommitDialogState();
}

class _CommitDialogState extends State<_CommitDialog> {
  final _repository = TextEditingController();
  final _tag = TextEditingController(text: 'latest');

  @override
  void dispose() {
    _repository.dispose();
    _tag.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('导出为镜像'),
      content: DialogBody(
        maxWidth: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _repository,
              decoration: const InputDecoration(
                labelText: '仓库',
                hintText: 'hampanel/my-image',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _tag,
              decoration: const InputDecoration(labelText: '标签'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (_repository.text.trim().isEmpty) return;
            Navigator.pop(context, (
              repository: _repository.text.trim(),
              tag: _tag.text.trim().isEmpty ? 'latest' : _tag.text.trim(),
            ));
          },
          child: const Text('提交'),
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

List<String> _splitCommand(String value) {
  final result = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        result.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty) result.add(buffer.toString());
  return result;
}
