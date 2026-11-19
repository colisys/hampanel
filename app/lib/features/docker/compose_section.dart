import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/log_page.dart';
import '../../ui/widgets.dart';
import 'job_progress_dialog.dart';

class ComposeSection extends StatefulWidget {
  const ComposeSection({super.key, this.refreshEpoch = 0});

  final int refreshEpoch;

  @override
  State<ComposeSection> createState() => _ComposeSectionState();
}

class _ComposeSectionState extends State<ComposeSection> {

  @override
  void didUpdateWidget(covariant ComposeSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.refreshEpoch != widget.refreshEpoch) _load();
  }
  List<DockerComposeProject> _projects = const [];
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
      final json = await _api.getJson('/api/v1/docker/compose');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _projects = ((map['projects'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerComposeProject.fromJson)
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
      builder: (context) => ComposeEditorDialog(api: _api),
    );
    if (created == true) {
      _toast('编排项目已创建');
      await _load();
    }
  }

  Future<void> _edit(DockerComposeProject project) async {
    if (!project.managed) {
      await _adopt(project);
      return;
    }
    try {
      final json = await _api.getJson('/api/v1/docker/compose/${project.name}');
      final detail = DockerComposeDetail.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      final changed = await showDialog<bool>(
        context: context,
        builder: (context) => ComposeEditorDialog(api: _api, detail: detail),
      );
      if (changed == true) {
        _toast('compose 文件已保存');
        await _load();
      }
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _adopt(DockerComposeProject project) async {
    if (project.configFiles.isEmpty) {
      _toast('该项目没有可读的 compose 文件，无法接管');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: '接管 ${project.name}?',
      message:
          '会将 compose 文件复制到 hampanel 的编排目录，并保留原项目名。'
          '相对路径仍通过原目录解析。',
      confirmLabel: '接管',
    );
    if (!ok) return;
    try {
      await _api.postJson('/api/v1/docker/compose/adopt', {
        'name': project.name,
        'config_files': project.configFiles,
      });
      _toast('已接管 ${project.name}');
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _adoptDialog() async {
    final candidates = _projects.where((project) => !project.managed).toList();
    if (candidates.isEmpty) {
      _toast('没有可接管的外部 compose 项目');
      return;
    }
    final selected = await showDialog<DockerComposeProject>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('接管外部编排项目'),
        children: [
          for (final project in candidates)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, project),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(project.name),
                  Text(
                    project.configFiles.isEmpty
                        ? '没有可读的 compose 文件'
                        : project.configFiles.join(', '),
                    style: TextStyle(fontSize: 10.5, color: hampanelMuted),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
    if (selected != null) await _adopt(selected);
  }

  Future<void> _action(DockerComposeProject project, String action) async {
    if (!project.managed) {
      _toast('请先接管该项目');
      return;
    }
    try {
      final json = await _api.postJson(
        '/api/v1/docker/compose/${project.name}/$action',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) {
        if (!mounted) return;
        await showDockerJob(
          context,
          _api,
          jobId,
          title: '${project.name} · $action',
        );
      } else {
        final output = (map['output'] as String? ?? '').trim();
        if (output.isNotEmpty) _toast(output);
      }
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _logs(DockerComposeProject project) async {
    final api = _api;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogPage(
          title: '${project.name} 日志',
          emptyMessage: '暂无日志',
          load: (lines) async {
            final json = await api.getJson(
              '/api/v1/docker/compose/${project.name}/logs',
              query: {'lines': '$lines'},
            );
            final map = json as Map<String, dynamic>? ?? const {};
            return LogPageData(content: map['output'] as String? ?? '');
          },
        ),
      ),
    );
  }

  Future<void> _delete(DockerComposeProject project) async {
    if (!project.managed) {
      _toast('外部项目不支持删除');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: '删除编排 ${project.name}?',
      message: '会先执行 compose down，再删除 hampanel 保存的 compose 文件。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.deleteJson(
        '/api/v1/docker/compose/${project.name}',
        query: const {'down': '1'},
      );
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
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
          title: '编排管理',
          subtitle: '${_projects.length} 个 compose 项目',
          actions: [
            FilledButton.icon(
              onPressed: _create,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建编排'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _adoptDialog,
              icon: const Icon(Icons.move_to_inbox_outlined, size: 16),
              label: const Text('接管外部项目'),
            ),
            PageRefreshButton(onPressed: _load),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _projects.isEmpty
              ? EmptyState(
                  icon: Icons.account_tree_outlined,
                  title: '没有编排项目',
                  message: '新建一个 compose 项目，或接管宿主机上已有的项目。',
                  action: FilledButton.icon(
                    onPressed: _create,
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('新建编排'),
                  ),
                )
              : ListView.separated(
                  padding: pageContentPadding(context, top: 8),
                  itemCount: _projects.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final project = _projects[index];
                    return _ComposeCard(
                      project: project,
                      onAction: (action) => _action(project, action),
                      onEdit: () => _edit(project),
                      onAdopt: () => _adopt(project),
                      onLogs: () => _logs(project),
                      onDelete: () => _delete(project),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ComposeCard extends StatelessWidget {
  const _ComposeCard({
    required this.project,
    required this.onAction,
    required this.onEdit,
    required this.onAdopt,
    required this.onLogs,
    required this.onDelete,
  });

  final DockerComposeProject project;
  final ValueChanged<String> onAction;
  final VoidCallback onEdit;
  final VoidCallback onAdopt;
  final VoidCallback onLogs;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 20,
                  color: project.managed ? hampanelAccent : hampanelMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            project.name,
                            style: const TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(width: 8),
                          _Badge(
                            text: project.managed
                                ? (project.adopted ? '已接管' : '受管理')
                                : '外部项目',
                            accent: project.managed,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        project.managed
                            ? (project.sourceDir.isEmpty
                                  ? project.dir
                                  : '${project.dir} · 相对路径 ${project.sourceDir}')
                            : project.configFiles.isEmpty
                            ? '无配置文件'
                            : project.configFiles.join(', '),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: hampanelMuted),
                      ),
                    ],
                  ),
                ),
                if (project.status.isNotEmpty)
                  Text(
                    project.status,
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                const SizedBox(width: 8),
                if (project.managed) ...[
                  IconButton(
                    tooltip: '启动',
                    onPressed: () => onAction('up'),
                    icon: const Icon(Icons.play_arrow, size: 18),
                  ),
                  IconButton(
                    tooltip: '重启',
                    onPressed: () => onAction('restart'),
                    icon: const Icon(Icons.restart_alt, size: 18),
                  ),
                  IconButton(
                    tooltip: '停止',
                    onPressed: () => onAction('down'),
                    icon: const Icon(Icons.stop, size: 18),
                  ),
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_horiz, size: 18),
                    onSelected: (value) {
                      switch (value) {
                        case 'edit':
                          onEdit();
                        case 'logs':
                          onLogs();
                        case 'pull':
                          onAction('pull');
                        case 'delete':
                          onDelete();
                      }
                    },
                    itemBuilder: (context) => const [
                      PopupMenuItem(value: 'edit', child: Text('编辑配置')),
                      PopupMenuItem(value: 'logs', child: Text('日志')),
                      PopupMenuItem(value: 'pull', child: Text('拉取镜像')),
                      PopupMenuItem(value: 'delete', child: Text('删除')),
                    ],
                  ),
                ] else
                  TextButton.icon(
                    onPressed: onAdopt,
                    icon: const Icon(Icons.move_to_inbox_outlined, size: 16),
                    label: const Text('接管'),
                  ),
              ],
            ),
            if (project.files.isNotEmpty) ...[
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 4,
                children: [
                  for (final file in project.files)
                    Text(
                      file,
                      style: monospace.copyWith(
                        fontSize: 10.5,
                        color: hampanelMuted,
                      ),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.accent});

  final String text;
  final bool accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: accent ? hampanelAccent : hampanelBorder),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 9.5,
          color: accent ? hampanelAccent : hampanelMuted,
        ),
      ),
    );
  }
}

class ComposeEditorDialog extends StatefulWidget {
  const ComposeEditorDialog({super.key, required this.api, this.detail});

  final ApiClient api;
  final DockerComposeDetail? detail;

  @override
  State<ComposeEditorDialog> createState() => _ComposeEditorDialogState();
}

class _ComposeEditorDialogState extends State<ComposeEditorDialog> {
  late final TextEditingController _name;
  late final TextEditingController _content;
  bool _saving = false;
  String? _error;

  bool get _editing => widget.detail != null;

  ApiClient get _api => widget.api;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.detail?.project.name ?? '');
    _content = TextEditingController(text: widget.detail?.content ?? '');
  }

  @override
  void dispose() {
    _name.dispose();
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _content.text.trim().isEmpty) {
      setState(() => _error = '项目名称和 compose 内容不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_editing) {
        await _api.putJson(
          '/api/v1/docker/compose/${widget.detail!.project.name}',
          {'content': _content.text},
        );
      } else {
        await _api.postJson('/api/v1/docker/compose', {
          'name': _name.text.trim(),
          'content': _content.text,
        });
      }
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
      title: Text(_editing ? '编辑 compose' : '新建 compose 项目'),
      content: DialogBody(
        maxWidth: 760,
        maxHeight: 640,
        child: Column(
          children: [
            TextField(
              controller: _name,
              enabled: !_editing,
              decoration: const InputDecoration(
                labelText: '项目名称',
                hintText: 'my-stack',
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _content,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                style: monospace.copyWith(fontSize: 12),
                decoration: const InputDecoration(
                  labelText: 'compose.yml',
                  alignLabelWithHint: true,
                  hintText: 'services:\n  web:\n    image: nginx:alpine\n',
                ),
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
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
