import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/runtime_env.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';

class RuntimesPage extends StatefulWidget {
  const RuntimesPage({super.key});

  @override
  State<RuntimesPage> createState() => _RuntimesPageState();
}

class _RuntimesPageState extends State<RuntimesPage> {
  RuntimeCatalog? _catalog;
  List<RuntimeEnvironment> _environments = const [];
  bool _loading = true;
  String? _error;
  bool _busy = false;

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
      final catalogJson = await _api.getJson('/api/v1/runtimes/catalog');
      final envJson = await _api.getJson('/api/v1/runtimes');
      if (!mounted) return;
      setState(() {
        _catalog = RuntimeCatalog.fromJson(catalogJson as Map<String, dynamic>);
        _environments =
            (((envJson as Map<String, dynamic>?)?['environments']
                        as List<dynamic>?) ??
                    const [])
                .whereType<Map<String, dynamic>>()
                .map(RuntimeEnvironment.fromJson)
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
    final catalog = _catalog;
    if (catalog == null) return;
    final request = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _CreateRuntimeDialog(api: _api, catalog: catalog),
    );
    if (request == null) return;
    setState(() => _busy = true);
    try {
      final result = await _api.postJson(
        '/api/v1/runtimes',
        request,
        timeout: const Duration(minutes: 10),
      );
      final map = result as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] != true) {
        await showOutputDialog(
          context,
          '创建失败',
          map['output'] as String? ?? '未知错误',
        );
      } else {
        _toast('环境已创建');
      }
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _action(RuntimeEnvironment env, String action) async {
    setState(() => _busy = true);
    try {
      final result = await _api.postJson(
        '/api/v1/runtimes/${env.id}/$action',
        const {},
        timeout: const Duration(minutes: 10),
      );
      final map = result as Map<String, dynamic>? ?? const {};
      if (map['ok'] == false) {
        if (!mounted) return;
        await showOutputDialog(
          context,
          '操作失败',
          map['output'] as String? ?? '未知错误',
        );
      }
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _delete(RuntimeEnvironment env, {required bool volumes}) async {
    final ok = await confirmDialog(
      context,
      title: '删除 ${env.name}?',
      message: volumes ? '容器与命名数据卷都会被删除，数据无法恢复。' : '容器会被删除，命名数据卷会保留。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    setState(() => _busy = true);
    try {
      await _api.deleteJson(
        '/api/v1/runtimes/${env.id}',
        query: volumes ? {'volumes': 'true'} : null,
      );
      _toast('${env.name} 已删除');
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
      await _load();
    }
  }

  Future<void> _manage(RuntimeEnvironment env) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _EnvironmentDetailDialog(
        api: _api,
        env: env,
        preset: _catalog?.presetById(env.runtime),
        onChanged: _load,
      ),
    );
  }

  Future<void> _logs(RuntimeEnvironment env) async {
    try {
      final json = await _api.getJson(
        '/api/v1/runtimes/${env.id}/logs',
        query: {'lines': '300'},
      );
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      await showOutputDialog(
        context,
        '${env.name} 日志',
        map['output'] as String? ?? '',
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _configs(RuntimeEnvironment env) async {
    try {
      final json = await _api.getJson('/api/v1/runtimes/${env.id}/config');
      final files =
          (((json as Map<String, dynamic>)['files'] as List<dynamic>?) ??
                  const [])
              .whereType<Map<String, dynamic>>()
              .map(RuntimeConfigFile.fromJson)
              .toList();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _ConfigDialog(api: _api, env: env, files: files),
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _extensions(RuntimeEnvironment env) async {
    final preset = _catalog?.presetById(env.runtime);
    if (preset == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ExtensionsDialog(
        api: _api,
        env: env,
        preset: preset,
        onChanged: _load,
      ),
    );
  }

  Future<void> _processes(RuntimeEnvironment env) async {
    await showDialog<void>(
      context: context,
      builder: (_) => _ProcessesDialog(api: _api, env: env),
    );
  }

  Future<void> _dockerSettings() async {
    try {
      final json = await _api.getJson('/api/v1/docker/settings');
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => _DockerSettingsDialog(
          api: _api,
          initial: json as Map<String, dynamic>,
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
          title: '运行环境',
          subtitle: '借宿主机 Docker 运行的隔离运行时 · 配置、扩展与进程统一管理',
          actions: [
            OutlinedButton.icon(
              onPressed: _busy ? null : _dockerSettings,
              icon: const Icon(Icons.settings_ethernet, size: 16),
              label: const Text('Docker 设置'),
            ),
            const SizedBox(width: 10),
            FilledButton.icon(
              onPressed: _busy ? null : _create,
              icon: const Icon(Icons.add, size: 17),
              label: const Text('新环境'),
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
              : _environments.isEmpty
              ? EmptyState(
                  icon: Icons.hub_outlined,
                  title: '还没有运行环境',
                  message: '创建一个 Node、Python、PHP 或自定义镜像环境，由面板管理其生命周期。',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                    itemCount: _environments.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 10),
                    itemBuilder: (context, index) {
                      final env = _environments[index];
                      return _EnvironmentCard(
                        env: env,
                        busy: _busy,
                        onAction: (action) {
                          if (action == 'manage') {
                            _manage(env);
                          } else if (action == 'logs') {
                            _logs(env);
                          } else if (action == 'config') {
                            _configs(env);
                          } else if (action == 'extensions') {
                            _extensions(env);
                          } else if (action == 'processes') {
                            _processes(env);
                          } else if (action == 'delete') {
                            _delete(env, volumes: false);
                          } else if (action == 'delete-volumes') {
                            _delete(env, volumes: true);
                          } else {
                            _action(env, action);
                          }
                        },
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }
}

class _EnvironmentCard extends StatelessWidget {
  const _EnvironmentCard({
    required this.env,
    required this.busy,
    required this.onAction,
  });

  final RuntimeEnvironment env;
  final bool busy;
  final ValueChanged<String> onAction;

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: env.name,
      trailing: StatusPill(
        text: env.running ? '运行中' : env.status,
        good: env.running,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${env.runtime} · ${env.imageRef}',
                  style: monospace.copyWith(fontSize: 11.5),
                ),
              ),
              if (env.port != null)
                Text(
                  '端口 ${env.port}',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
              if (env.cpu != null) ...[
                const SizedBox(width: 12),
                Text(
                  'CPU ${env.cpu}',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
              ],
              if (env.memoryMb != null) ...[
                const SizedBox(width: 12),
                Text(
                  '内存 ${env.memoryMb} MB',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '配置版本 ${env.configVersion} · 扩展 ${env.extensions.isEmpty ? '无' : env.extensions.join(', ')}',
            style: TextStyle(fontSize: 11, color: hampanelMuted),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: busy ? null : () => onAction('manage'),
                child: const Text('管理'),
              ),
              FilledButton(
                onPressed: busy ? null : () => onAction('start'),
                child: const Text('启动'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('stop'),
                child: const Text('停止'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('restart'),
                child: const Text('重启'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('logs'),
                child: const Text('日志'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('config'),
                child: const Text('配置'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('extensions'),
                child: const Text('扩展'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('processes'),
                child: const Text('进程'),
              ),
              OutlinedButton(
                onPressed: busy ? null : () => onAction('rebuild'),
                child: const Text('重建镜像'),
              ),
              PopupMenuButton<String>(
                tooltip: '删除',
                icon: const Icon(Icons.more_horiz, size: 18),
                onSelected: onAction,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'delete', child: Text('删除（保留数据）')),
                  PopupMenuItem(
                    value: 'delete-volumes',
                    child: Text('删除并删除数据卷'),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CreateRuntimeDialog extends StatefulWidget {
  const _CreateRuntimeDialog({required this.api, required this.catalog});

  final ApiClient api;
  final RuntimeCatalog catalog;

  @override
  State<_CreateRuntimeDialog> createState() => _CreateRuntimeDialogState();
}

class _CreateRuntimeDialogState extends State<_CreateRuntimeDialog> {
  final _name = TextEditingController();
  final _image = TextEditingController();
  final _tag = TextEditingController();
  final _port = TextEditingController();
  final _cpu = TextEditingController();
  final _memory = TextEditingController();
  final _customMirror = TextEditingController();
  RuntimePreset? _preset;
  String _mirror = '';
  final Set<String> _extensions = {};
  List<String> _tags = const [];

  @override
  void initState() {
    super.initState();
    _selectPreset(widget.catalog.runtimes.first);
  }

  @override
  void dispose() {
    for (final controller in [
      _name,
      _image,
      _tag,
      _port,
      _cpu,
      _memory,
      _customMirror,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _selectPreset(RuntimePreset preset) {
    setState(() {
      _preset = preset;
      _image.text = preset.image;
      _tag.text = preset.tag;
      _port.text = '${preset.webPort}';
      _extensions.clear();
      _tags = preset.recommendedTags;
    });
    _loadTags(preset);
  }

  Future<void> _loadTags(RuntimePreset preset) async {
    try {
      final json = await widget.api.getJson(
        '/api/v1/runtimes/catalog/${preset.id}/tags',
      );
      final tags =
          (((json as Map<String, dynamic>)['tags'] as List<dynamic>?) ??
                  const [])
              .whereType<String>()
              .toList();
      if (!mounted || _preset?.id != preset.id) return;
      setState(() => _tags = tags);
    } catch (_) {
      // keep recommended tags
    }
  }

  void _submit() {
    final preset = _preset;
    if (preset == null) return;
    if (_name.text.trim().isEmpty) return;
    final custom = _customMirror.text.trim();
    final request = <String, dynamic>{
      'name': _name.text.trim(),
      'runtime': preset.id,
      'image': _image.text.trim(),
      'tag': _tag.text.trim(),
      'extensions': _extensions.toList(),
      'pkg_mirror': custom.isEmpty
          ? _mirror
          : (custom.startsWith('http') ? 'custom:$custom' : custom),
    };
    final port = int.tryParse(_port.text.trim());
    if (port != null) request['port'] = port;
    final cpu = double.tryParse(_cpu.text.trim());
    if (cpu != null) request['cpu'] = cpu;
    final memory = int.tryParse(_memory.text.trim());
    if (memory != null) request['memory_mb'] = memory;
    Navigator.of(context).pop(request);
  }

  @override
  Widget build(BuildContext context) {
    final preset = _preset;
    return AlertDialog(
      title: const Text('新建运行环境'),
      content: DialogBody(
        maxWidth: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DropdownButtonFormField<String>(
                initialValue: preset?.id,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '运行时'),
                items: [
                  for (final runtime in widget.catalog.runtimes)
                    DropdownMenuItem(
                      value: runtime.id,
                      child: Text(
                        '${runtime.name}（${runtime.description}）',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) {
                  final found = widget.catalog.presetById(value ?? '');
                  if (found != null) _selectPreset(found);
                },
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '例如 node-api',
                ),
              ),
              const SizedBox(height: 10),
              FormRow(
                flex: const [3, 2],
                children: [
                  TextField(
                    controller: _image,
                    decoration: const InputDecoration(labelText: '镜像'),
                  ),
                  TextField(
                    controller: _tag,
                    decoration: const InputDecoration(labelText: 'Tag / 版本'),
                  ),
                ],
              ),
              if (preset != null && preset.recommendedTags.isNotEmpty) ...[
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: [
                    for (final tag in _tags.take(16))
                      ActionChip(
                        label: Text(
                          tag,
                          style: const TextStyle(fontSize: 10.5),
                        ),
                        onPressed: () => setState(() => _tag.text = tag),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              FormRow(
                children: [
                  TextField(
                    controller: _port,
                    decoration: const InputDecoration(labelText: '宿主端口'),
                  ),
                  TextField(
                    controller: _cpu,
                    decoration: const InputDecoration(
                      labelText: 'CPU 限额（可选）',
                      hintText: '1.0',
                    ),
                  ),
                  TextField(
                    controller: _memory,
                    decoration: const InputDecoration(
                      labelText: '内存 MB（可选）',
                      hintText: '512',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _mirror,
                isExpanded: true,
                decoration: const InputDecoration(labelText: '镜像内包管理器镜像源'),
                items: [
                  const DropdownMenuItem(value: '', child: Text('不配置')),
                  for (final mirror in widget.catalog.mirrors)
                    DropdownMenuItem(
                      value: mirror.id,
                      child: Text(
                        mirror.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (value) => setState(() => _mirror = value ?? ''),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _customMirror,
                decoration: const InputDecoration(
                  labelText: '自定义镜像源 URL（可选，优先于上面的预设）',
                  hintText: 'https://mirrors.example.com',
                ),
              ),
              if (preset != null && preset.extensions.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  '扩展 / 插件',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    for (final extension in preset.extensions)
                      FilterChip(
                        label: Text(extension.label),
                        selected: _extensions.contains(extension.id),
                        onSelected: (selected) => setState(() {
                          if (selected) {
                            _extensions.add(extension.id);
                          } else {
                            _extensions.remove(extension.id);
                          }
                        }),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('创建并启动')),
      ],
    );
  }
}

class _ConfigDialog extends StatefulWidget {
  const _ConfigDialog({
    required this.api,
    required this.env,
    required this.files,
  });

  final ApiClient api;
  final RuntimeEnvironment env;
  final List<RuntimeConfigFile> files;

  @override
  State<_ConfigDialog> createState() => _ConfigDialogState();
}

class _ConfigDialogState extends State<_ConfigDialog> {
  late final TextEditingController _content;
  String? _file;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController();
    if (widget.files.isNotEmpty) {
      _file = widget.files.first.path;
      _content.text = widget.files.first.content;
    }
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_file == null) return;
    setState(() => _busy = true);
    try {
      final result = await widget.api.putJson(
        '/api/v1/runtimes/${widget.env.id}/config',
        {'file': _file, 'content': _content.text},
      );
      final map = result as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] != true) {
        await showOutputDialog(context, '保存失败', map['output'] as String? ?? '');
      } else {
        if (mounted) Navigator.of(context).pop();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(error))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.env.name} · 配置'),
      content: DialogBody(
        maxWidth: 820,
        maxHeight: 560,
        child: Column(
          children: [
            if (widget.files.isNotEmpty)
              DropdownButtonFormField<String>(
                initialValue: _file,
                decoration: const InputDecoration(labelText: '配置文件'),
                items: [
                  for (final file in widget.files)
                    DropdownMenuItem(value: file.path, child: Text(file.path)),
                ],
                onChanged: (value) {
                  final file = widget.files.firstWhere((f) => f.path == value);
                  setState(() {
                    _file = value;
                    _content.text = file.content;
                  });
                },
              ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _content,
                expands: true,
                maxLines: null,
                style: monospace.copyWith(fontSize: 12),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
        FilledButton(
          onPressed: _busy || _file == null ? null : _save,
          child: Text(_busy ? '保存中…' : '保存并应用'),
        ),
      ],
    );
  }
}

class _ExtensionsDialog extends StatefulWidget {
  const _ExtensionsDialog({
    required this.api,
    required this.env,
    required this.preset,
    required this.onChanged,
  });

  final ApiClient api;
  final RuntimeEnvironment env;
  final RuntimePreset preset;
  final Future<void> Function() onChanged;

  @override
  State<_ExtensionsDialog> createState() => _ExtensionsDialogState();
}

class _ExtensionsDialogState extends State<_ExtensionsDialog> {
  late Set<String> _selected;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _selected = {...widget.env.extensions};
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final result = await widget.api.putJson(
        '/api/v1/runtimes/${widget.env.id}/extensions',
        {'extensions': _selected.toList()},
      );
      final map = result as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] != true) {
        await showOutputDialog(context, '重建失败', map['output'] as String? ?? '');
      } else {
        await widget.onChanged();
        if (mounted) Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.env.name} · 扩展'),
      content: DialogBody(
        maxWidth: 520,
        child: widget.preset.extensions.isEmpty
            ? const Text('该运行时没有可选的扩展。')
            : Wrap(
                spacing: 8,
                runSpacing: 6,
                children: [
                  for (final extension in widget.preset.extensions)
                    FilterChip(
                      label: Text(extension.label),
                      selected: _selected.contains(extension.id),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _selected.add(extension.id);
                        } else {
                          _selected.remove(extension.id);
                        }
                      }),
                    ),
                ],
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '重建中…' : '保存并重建'),
        ),
      ],
    );
  }
}

class _ProcessesDialog extends StatefulWidget {
  const _ProcessesDialog({required this.api, required this.env});

  final ApiClient api;
  final RuntimeEnvironment env;

  @override
  State<_ProcessesDialog> createState() => _ProcessesDialogState();
}

class _ProcessesDialogState extends State<_ProcessesDialog> {
  final _process = TextEditingController();
  String _output = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _process.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final json = await widget.api.getJson(
        '/api/v1/runtimes/${widget.env.id}/processes',
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final output = map['output'] as String? ?? '';
      if (!mounted) return;
      setState(() {
        _output = output;
        if (_process.text.isEmpty) {
          final first = output.split('\n').first.trim().split(' ').first;
          if (first.isNotEmpty) _process.text = first;
        }
      });
    } catch (error) {
      if (mounted) setState(() => _output = describeError(error));
    }
  }

  Future<void> _act(String action) async {
    final name = _process.text.trim();
    if (name.isEmpty) return;
    setState(() => _busy = true);
    try {
      final json = await widget.api.postJson(
        '/api/v1/runtimes/${widget.env.id}/processes/$name/$action',
        const {},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] != true) {
        await showOutputDialog(context, '操作失败', map['output'] as String? ?? '');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
      await _refresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${widget.env.name} · 进程'),
      content: DialogBody(
        maxWidth: 720,
        maxHeight: 420,
        child: Column(
          children: [
            FieldWithActions(
              field: TextField(
                controller: _process,
                decoration: const InputDecoration(labelText: '进程名'),
              ),
              actions: [
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('start'),
                  child: const Text('启动'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('stop'),
                  child: const Text('停止'),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : () => _act('restart'),
                  child: const Text('重启'),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF0B1116),
                  border: Border.all(color: hampanelInk, width: 2),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _output,
                    style: monospace.copyWith(
                      fontSize: 11.5,
                      color: const Color(0xFFE8E0CE),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: _refresh, child: const Text('刷新')),
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _DockerSettingsDialog extends StatefulWidget {
  const _DockerSettingsDialog({required this.api, required this.initial});

  final ApiClient api;
  final Map<String, dynamic> initial;

  @override
  State<_DockerSettingsDialog> createState() => _DockerSettingsDialogState();
}

class _DockerSettingsDialogState extends State<_DockerSettingsDialog> {
  late final TextEditingController _mirrors;
  late final TextEditingController _cidr;
  late bool _ipv6;
  late bool _experimental;
  bool _restart = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final mirrors =
        ((widget.initial['registry_mirrors'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .join('\n');
    _mirrors = TextEditingController(text: mirrors);
    _cidr = TextEditingController(
      text: widget.initial['fixed_cidr_v6'] as String? ?? '',
    );
    _ipv6 = widget.initial['ipv6'] as bool? ?? false;
    _experimental = widget.initial['experimental'] as bool? ?? false;
  }

  @override
  void dispose() {
    _mirrors.dispose();
    _cidr.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final mirrors = _mirrors.text
          .split('\n')
          .map((line) => line.trim())
          .where((line) => line.isNotEmpty)
          .toList();
      final result = await widget.api.putJson('/api/v1/docker/settings', {
        'registry_mirrors': mirrors,
        'ipv6': _ipv6,
        'experimental': _experimental,
        'fixed_cidr_v6': _cidr.text.trim(),
        'restart': _restart,
      });
      final map = result as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] != true) {
        await showOutputDialog(context, '保存失败', map['output'] as String? ?? '');
      } else {
        await showOutputDialog(
          context,
          'Docker 设置',
          map['output'] as String? ?? '已保存',
        );
        if (mounted) Navigator.of(context).pop();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Docker 守护进程设置'),
      content: DialogBody(
        maxWidth: 620,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _mirrors,
                minLines: 4,
                maxLines: 8,
                decoration: const InputDecoration(
                  labelText: '镜像源 registry-mirrors（每行一个）',
                  hintText: 'https://mirror.example.com',
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 IPv6'),
                value: _ipv6,
                onChanged: (value) => setState(() => _ipv6 = value),
              ),
              if (_ipv6)
                TextField(
                  controller: _cidr,
                  decoration: const InputDecoration(
                    labelText: 'fixed-cidr-v6（可选）',
                    hintText: 'fd00::/64',
                  ),
                ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('启用 experimental 特性'),
                value: _experimental,
                onChanged: (value) => setState(() => _experimental = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('保存后重启 Docker'),
                subtitle: const Text('会中断正在运行的容器'),
                value: _restart,
                onChanged: (value) => setState(() => _restart = value),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}

/// 运行环境详情：日志 / 配置 / 扩展 / 进程统一用标签页切换。
class _EnvironmentDetailDialog extends StatelessWidget {
  const _EnvironmentDetailDialog({
    required this.api,
    required this.env,
    required this.preset,
    required this.onChanged,
  });

  final ApiClient api;
  final RuntimeEnvironment env;
  final RuntimePreset? preset;
  final Future<void> Function() onChanged;

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 4,
      child: AlertDialog(
        title: Text('${env.name} · 运行环境'),
        content: DialogBody(
          maxWidth: 920,
          maxHeight: 580,
          child: Column(
            children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    Tab(text: '日志'),
                    Tab(text: '配置'),
                    Tab(text: '扩展'),
                    Tab(text: '进程'),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Expanded(
                child: TabBarView(
                  children: [
                    _RuntimeLogsTab(api: api, env: env),
                    _RuntimeConfigTab(api: api, env: env),
                    _RuntimeExtensionsTab(
                      api: api,
                      env: env,
                      preset: preset,
                      onChanged: onChanged,
                    ),
                    _RuntimeProcessesTab(api: api, env: env),
                  ],
                ),
              ),
            ],
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
  }
}

class _RuntimeLogsTab extends StatefulWidget {
  const _RuntimeLogsTab({required this.api, required this.env});

  final ApiClient api;
  final RuntimeEnvironment env;

  @override
  State<_RuntimeLogsTab> createState() => _RuntimeLogsTabState();
}

class _RuntimeLogsTabState extends State<_RuntimeLogsTab> {
  String? _text;
  String? _error;
  bool _loading = true;

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
      final json = await widget.api.getJson(
        '/api/v1/runtimes/${widget.env.id}/logs',
        query: {'lines': '300'},
      );
      if (!mounted) return;
      setState(() {
        _text = (json as Map<String, dynamic>)['output'] as String? ?? '';
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorBanner(message: _error!, onRetry: _load);
    return Column(
      children: [
        Row(
          children: [
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: hampanelSurfaceAlt,
              border: Border.all(color: hampanelBorder),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                (_text ?? '').isEmpty ? '暂无日志' : _text!,
                style: monospace.copyWith(fontSize: 11.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _RuntimeConfigTab extends StatefulWidget {
  const _RuntimeConfigTab({required this.api, required this.env});

  final ApiClient api;
  final RuntimeEnvironment env;

  @override
  State<_RuntimeConfigTab> createState() => _RuntimeConfigTabState();
}

class _RuntimeConfigTabState extends State<_RuntimeConfigTab> {
  final _content = TextEditingController();
  List<RuntimeConfigFile> _files = const [];
  String? _selected;
  String? _error;
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _content.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.api.getJson(
        '/api/v1/runtimes/${widget.env.id}/config',
      );
      final files =
          (((json as Map<String, dynamic>)['files'] as List<dynamic>?) ??
                  const [])
              .whereType<Map<String, dynamic>>()
              .map(RuntimeConfigFile.fromJson)
              .toList();
      if (!mounted) return;
      setState(() {
        _files = files;
        _selected = files.isEmpty ? null : files.first.path;
        _content.text = files.isEmpty ? '' : files.first.content;
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

  Future<void> _save() async {
    final file = _selected;
    if (file == null) return;
    setState(() => _busy = true);
    try {
      final json = await widget.api.putJson(
        '/api/v1/runtimes/${widget.env.id}/config',
        {'file': file, 'content': _content.text},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('配置已保存并应用')));
        await _load();
      } else {
        await showOutputDialog(context, '保存失败', map['output'] as String? ?? '');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorBanner(message: _error!, onRetry: _load);
    if (_files.isEmpty) {
      return const EmptyState(
        icon: Icons.description_outlined,
        title: '没有可编辑的配置文件',
      );
    }
    return Column(
      children: [
        FieldWithActions(
          field: DropdownButtonFormField<String>(
            initialValue: _selected,
            isExpanded: true,
            decoration: const InputDecoration(labelText: '配置文件', isDense: true),
            items: [
              for (final file in _files)
                DropdownMenuItem(
                  value: file.path,
                  child: Text(file.path, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) {
              final file = _files.firstWhere((item) => item.path == value);
              setState(() {
                _selected = value;
                _content.text = file.content;
              });
            },
          ),
          actions: [
            FilledButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? '保存中…' : '保存并应用'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Expanded(
          child: TextField(
            controller: _content,
            expands: true,
            maxLines: null,
            style: monospace.copyWith(fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
          ),
        ),
      ],
    );
  }
}

class _RuntimeExtensionsTab extends StatefulWidget {
  const _RuntimeExtensionsTab({
    required this.api,
    required this.env,
    required this.preset,
    required this.onChanged,
  });

  final ApiClient api;
  final RuntimeEnvironment env;
  final RuntimePreset? preset;
  final Future<void> Function() onChanged;

  @override
  State<_RuntimeExtensionsTab> createState() => _RuntimeExtensionsTabState();
}

class _RuntimeExtensionsTabState extends State<_RuntimeExtensionsTab> {
  Set<String> _selected = {};
  String? _error;
  bool _loading = true;
  bool _busy = false;

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
      final json = await widget.api.getJson(
        '/api/v1/runtimes/${widget.env.id}/extensions',
      );
      final list =
          ((json as Map<String, dynamic>)['extensions'] as List<dynamic>?) ??
          const [];
      if (!mounted) return;
      setState(() {
        _selected = list.whereType<String>().toSet();
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

  Future<void> _save() async {
    setState(() => _busy = true);
    try {
      final json = await widget.api.putJson(
        '/api/v1/runtimes/${widget.env.id}/extensions',
        {'extensions': _selected.toList()..sort()},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == true) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('扩展已保存，正在重建镜像')));
        await widget.onChanged();
      } else {
        await showOutputDialog(context, '保存失败', map['output'] as String? ?? '');
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(describeError(error))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorBanner(message: _error!, onRetry: _load);
    final extensions = widget.preset?.extensions ?? const [];
    if (extensions.isEmpty) {
      return const EmptyState(
        icon: Icons.extension_outlined,
        title: '该运行时没有可选的扩展',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '勾选后保存会重建镜像并重启环境。',
          style: TextStyle(fontSize: 11.5, color: hampanelMuted),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final extension in extensions)
              FilterChip(
                label: Text(extension.label),
                selected: _selected.contains(extension.id),
                onSelected: (value) => setState(() {
                  if (value) {
                    _selected.add(extension.id);
                  } else {
                    _selected.remove(extension.id);
                  }
                }),
              ),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton(
          onPressed: _busy ? null : _save,
          child: Text(_busy ? '重建中…' : '保存并重建'),
        ),
      ],
    );
  }
}

class _RuntimeProcessesTab extends StatefulWidget {
  const _RuntimeProcessesTab({required this.api, required this.env});

  final ApiClient api;
  final RuntimeEnvironment env;

  @override
  State<_RuntimeProcessesTab> createState() => _RuntimeProcessesTabState();
}

class _RuntimeProcessesTabState extends State<_RuntimeProcessesTab> {
  String? _output;
  String? _error;
  bool _loading = true;

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
      final json = await widget.api.getJson(
        '/api/v1/runtimes/${widget.env.id}/processes',
      );
      if (!mounted) return;
      setState(() {
        _output = (json as Map<String, dynamic>)['output'] as String? ?? '';
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

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    if (_error != null) return ErrorBanner(message: _error!, onRetry: _load);
    return Column(
      children: [
        Row(
          children: [
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: hampanelSurfaceAlt,
              border: Border.all(color: hampanelBorder),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                (_output ?? '').isEmpty ? '没有进程信息' : _output!,
                style: monospace.copyWith(fontSize: 11.5),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
