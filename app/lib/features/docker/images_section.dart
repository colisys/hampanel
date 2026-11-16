import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'job_progress_dialog.dart';

class ImagesSection extends StatefulWidget {
  const ImagesSection({super.key});

  @override
  State<ImagesSection> createState() => _ImagesSectionState();
}

class _ImagesSectionState extends State<ImagesSection> {
  List<DockerImage> _images = const [];
  List<DockerRegistry> _registries = const [];
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
      final results = await Future.wait([
        _api.getJson('/api/v1/docker/images'),
        _api.getJson('/api/v1/docker/registries'),
      ]);
      final imageMap = results[0] as Map<String, dynamic>? ?? const {};
      final registryMap = results[1] as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _images = ((imageMap['images'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerImage.fromJson)
            .toList();
        _registries =
            ((registryMap['registries'] as List<dynamic>?) ?? const [])
                .whereType<Map<String, dynamic>>()
                .map(DockerRegistry.fromJson)
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

  Future<void> _runJob(String jobId, String title) async {
    if (!mounted) return;
    await showDockerJob(context, _api, jobId, title: title);
    await _load();
  }

  Future<void> _pull() async {
    final reference = await textInputDialog(
      context,
      title: '拉取镜像',
      label: '镜像引用',
      initial: 'nginx:alpine',
    );
    if (reference == null || reference.trim().isEmpty) return;
    await _pullReference(reference.trim());
  }

  Future<void> _pullReference(String reference) async {
    try {
      final json = await _api.postJson('/api/v1/docker/images/pull', {
        'reference': reference,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '拉取 $reference');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _push(DockerImage image) async {
    try {
      final json = await _api.postJson('/api/v1/docker/images/push', {
        'reference': image.reference,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '推送 ${image.reference}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _update(DockerImage image) async {
    try {
      final json = await _api.postJson('/api/v1/docker/images/update', {
        'reference': image.reference,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '更新 ${image.reference}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _tag(DockerImage image) async {
    final target = await textInputDialog(
      context,
      title: '镜像标签',
      label: '新引用',
      initial: image.reference,
    );
    if (target == null || target.trim().isEmpty) return;
    try {
      await _api.postJson('/api/v1/docker/images/tag', {
        'source': image.reference,
        'target': target.trim(),
      });
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _export(DockerImage image) async {
    try {
      final json = await _api.postJson('/api/v1/docker/images/export', {
        'reference': image.reference,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '导出 ${image.reference}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _delete(DockerImage image) async {
    var force = false;
    if (image.inUse) {
      final ok = await confirmDialog(
        context,
        title: '镜像正在使用',
        message:
            '${image.reference} 正被 ${image.usedBy.join(', ')} 使用。'
            '强制删除可能影响这些容器。',
        confirmLabel: '强制删除',
        danger: true,
      );
      if (!ok) return;
      force = true;
    } else {
      final ok = await confirmDialog(
        context,
        title: '删除镜像 ${image.reference}?',
        message: '该操作不可撤销。',
        confirmLabel: '删除',
        danger: true,
      );
      if (!ok) return;
    }
    try {
      await _api.deleteJson(
        '/api/v1/docker/images/${image.id}',
        query: {if (force) 'force': '1'},
      );
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _import() async {
    final path = await textInputDialog(
      context,
      title: '导入镜像',
      label: '本机 tar 路径',
      initial: Platform.environment['HOME'] ?? '',
    );
    if (path == null || path.trim().isEmpty) return;
    try {
      final file = File(path.trim());
      if (!await file.exists()) {
        _toast('文件不存在');
        return;
      }
      final json = await _api.uploadBytes(
        '/api/v1/docker/images/import',
        const {},
        await file.readAsBytes(),
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '导入镜像');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _build() async {
    final request = await showDialog<_BuildRequest>(
      context: context,
      builder: (context) => const _BuildDialog(),
    );
    if (request == null) return;
    try {
      if (request.type == 'upload') {
        final file = File(request.localPath);
        if (!await file.exists()) {
          _toast('构建上下文文件不存在');
          return;
        }
        final name = _buildName(request.tag);
        final json = await _api.uploadBytes(
          '/api/v1/docker/images/build/upload',
          {
            'tag': request.tag,
            'name': name,
            if (request.dockerfile.isNotEmpty) 'dockerfile': request.dockerfile,
          },
          await file.readAsBytes(),
        );
        final map = json as Map<String, dynamic>? ?? const {};
        final jobId = map['job_id'] as String?;
        if (jobId != null) await _runJob(jobId, '构建 ${request.tag}');
        return;
      }
      final path = request.type == 'git'
          ? '/api/v1/docker/images/build/git'
          : '/api/v1/docker/images/build';
      final body = request.type == 'git'
          ? <String, dynamic>{
              'tag': request.tag,
              'url': request.url,
              'git_ref': request.gitRef,
              'subdir': request.subdir,
              'dockerfile': request.dockerfile,
            }
          : <String, dynamic>{
              'tag': request.tag,
              'context_path': request.contextPath,
              'dockerfile': request.dockerfile,
            };
      final json = await _api.postJson(path, body);
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '构建 ${request.tag}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _search() async {
    final reference = await showDialog<String>(
      context: context,
      builder: (context) => _SearchDialog(api: _api, registries: _registries),
    );
    if (reference != null) await _pullReference(reference);
  }

  Future<void> _prune({required bool all}) async {
    final ok = await confirmDialog(
      context,
      title: all ? '清理所有未使用镜像?' : '清理悬空镜像?',
      message: all ? '会删除所有未被容器使用的镜像。' : '只删除悬空（dangling）镜像。',
      confirmLabel: '清理',
      danger: true,
    );
    if (!ok) return;
    try {
      final json = await _api.postJson(
        '/api/v1/docker/images/prune',
        const {},
        query: {if (all) 'all': '1'},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '清理镜像');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _pruneCache() async {
    final ok = await confirmDialog(
      context,
      title: '清理构建缓存?',
      message: '会删除 Docker builder 缓存。',
      confirmLabel: '清理',
      danger: true,
    );
    if (!ok) return;
    try {
      final json = await _api.postJson(
        '/api/v1/docker/build-cache/prune',
        const {},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final jobId = map['job_id'] as String?;
      if (jobId != null) await _runJob(jobId, '清理构建缓存');
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
          title: '镜像管理',
          subtitle: '${_images.length} 个镜像 · ${_registries.length} 个源',
          actions: [
            FilledButton.icon(
              onPressed: _pull,
              icon: const Icon(Icons.download_outlined, size: 16),
              label: const Text('拉取'),
            ),
            const SizedBox(width: 6),
            TextButton.icon(
              onPressed: _search,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('检索'),
            ),
            TextButton.icon(
              onPressed: _import,
              icon: const Icon(Icons.file_upload_outlined, size: 16),
              label: const Text('导入'),
            ),
            TextButton.icon(
              onPressed: _build,
              icon: const Icon(Icons.build_outlined, size: 16),
              label: const Text('构建'),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 18),
              onSelected: (value) {
                if (value == 'prune') _prune(all: false);
                if (value == 'prune-all') _prune(all: true);
                if (value == 'cache') _pruneCache();
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'prune', child: Text('清理悬空镜像')),
                PopupMenuItem(value: 'prune-all', child: Text('清理未使用镜像')),
                PopupMenuItem(value: 'cache', child: Text('清理构建缓存')),
              ],
            ),
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
              : _images.isEmpty
              ? const EmptyState(
                  icon: Icons.layers_outlined,
                  title: '没有镜像',
                  message: '拉取、导入或构建镜像后会显示在这里。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  itemCount: _images.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final image = _images[index];
                    return _ImageCard(
                      image: image,
                      onPush: () => _push(image),
                      onUpdate: () => _update(image),
                      onExport: () => _export(image),
                      onTag: () => _tag(image),
                      onDelete: () => _delete(image),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _ImageCard extends StatelessWidget {
  const _ImageCard({
    required this.image,
    required this.onPush,
    required this.onUpdate,
    required this.onExport,
    required this.onTag,
    required this.onDelete,
  });

  final DockerImage image;
  final VoidCallback onPush;
  final VoidCallback onUpdate;
  final VoidCallback onExport;
  final VoidCallback onTag;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.layers_outlined,
              size: 20,
              color: image.inUse ? hampanelAccent : hampanelMuted,
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 3,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    image.reference,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    image.digest.isEmpty
                        ? image.id
                        : '${image.id} · ${image.digest}',
                    overflow: TextOverflow.ellipsis,
                    style: monospace.copyWith(fontSize: 10.5),
                  ),
                ],
              ),
            ),
            SizedBox(
              width: 90,
              child: Text(
                image.size,
                style: TextStyle(fontSize: 11, color: hampanelMuted),
              ),
            ),
            SizedBox(
              width: 140,
              child: Text(
                image.inUse ? image.usedBy.join(', ') : '未使用',
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: image.inUse ? hampanelAccent : hampanelMuted,
                ),
              ),
            ),
            SizedBox(
              width: 150,
              child: Text(
                image.createdAt,
                style: TextStyle(fontSize: 10.5, color: hampanelMuted),
              ),
            ),
            IconButton(
              tooltip: '更新',
              onPressed: onUpdate,
              icon: const Icon(Icons.sync, size: 17),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz, size: 18),
              onSelected: (value) {
                switch (value) {
                  case 'push':
                    onPush();
                  case 'export':
                    onExport();
                  case 'update':
                    onUpdate();
                  case 'tag':
                    onTag();
                  case 'delete':
                    onDelete();
                }
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 'push', child: Text('推送')),
                PopupMenuItem(value: 'export', child: Text('导出')),
                PopupMenuItem(value: 'update', child: Text('更新')),
                PopupMenuItem(value: 'tag', child: Text('标签')),
                PopupMenuItem(value: 'delete', child: Text('删除')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SearchDialog extends StatefulWidget {
  const _SearchDialog({required this.api, required this.registries});

  final ApiClient api;
  final List<DockerRegistry> registries;

  @override
  State<_SearchDialog> createState() => _SearchDialogState();
}

class _SearchDialogState extends State<_SearchDialog> {
  final _term = TextEditingController();
  String _registryId = '';
  List<DockerImageSearchResult> _results = const [];
  List<String> _repositories = const [];
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _term.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final term = _term.text.trim();
    if (term.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.api.getJson(
        '/api/v1/docker/images/search',
        query: {
          'term': term,
          if (_registryId.isNotEmpty) 'registry_id': _registryId,
        },
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _results = ((map['results'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerImageSearchResult.fromJson)
            .toList();
        _repositories = ((map['repositories'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .map((repo) => repo.contains(':') ? repo : '$repo:latest')
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('检索镜像'),
      content: DialogBody(
        maxWidth: 700,
        maxHeight: 560,
        child: Column(
          children: [
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _term,
                    autofocus: true,
                    decoration: const InputDecoration(
                      labelText: '关键词',
                      hintText: 'nginx',
                    ),
                    onSubmitted: (_) => _search(),
                  ),
                ),
                const SizedBox(width: 8),
                DropdownButtonFormField<String>(
                  initialValue: _registryId,
                  decoration: const InputDecoration(labelText: '检索源'),
                  items: [
                    const DropdownMenuItem(
                      value: '',
                      child: Text('Docker Hub'),
                    ),
                    for (final registry in widget.registries)
                      DropdownMenuItem(
                        value: registry.id,
                        child: Text(registry.name),
                      ),
                  ],
                  onChanged: (value) =>
                      setState(() => _registryId = value ?? ''),
                ),
                const SizedBox(width: 8),
                IconButton(
                  onPressed: _loading ? null : _search,
                  icon: const Icon(Icons.search),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: hampanelDanger),
              ),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const LoadingView()
                  : ListView(
                      children: [
                        for (final result in _results)
                          ListTile(
                            dense: true,
                            title: Row(
                              children: [
                                Text(result.name),
                                if (result.official) ...[
                                  const SizedBox(width: 6),
                                  Text(
                                    '官方',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: hampanelAccent,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                            subtitle: Text(
                              result.description,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            trailing: Text(
                              '★ ${result.stars}',
                              style: TextStyle(
                                fontSize: 11,
                                color: hampanelMuted,
                              ),
                            ),
                            onTap: () =>
                                Navigator.pop(context, '${result.name}:latest'),
                          ),
                        for (final repository in _repositories)
                          ListTile(
                            dense: true,
                            leading: const Icon(
                              Icons.layers_outlined,
                              size: 18,
                            ),
                            title: Text(repository),
                            onTap: () => Navigator.pop(context, repository),
                          ),
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
    );
  }
}

class _BuildRequest {
  const _BuildRequest({
    required this.type,
    required this.tag,
    this.url = '',
    this.gitRef = '',
    this.subdir = '',
    this.contextPath = '',
    this.dockerfile = '',
    this.localPath = '',
  });

  final String type;
  final String tag;
  final String url;
  final String gitRef;
  final String subdir;
  final String contextPath;
  final String dockerfile;
  final String localPath;
}

class _BuildDialog extends StatefulWidget {
  const _BuildDialog();

  @override
  State<_BuildDialog> createState() => _BuildDialogState();
}

class _BuildDialogState extends State<_BuildDialog> {
  final _tag = TextEditingController();
  final _url = TextEditingController();
  final _gitRef = TextEditingController();
  final _subdir = TextEditingController();
  final _context = TextEditingController();
  final _dockerfile = TextEditingController();
  final _local = TextEditingController();
  String _type = 'git';

  @override
  void dispose() {
    _tag.dispose();
    _url.dispose();
    _gitRef.dispose();
    _subdir.dispose();
    _context.dispose();
    _dockerfile.dispose();
    _local.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('构建镜像'),
      content: DialogBody(
        maxWidth: 640,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'git', label: Text('Git')),
                  ButtonSegment(value: 'path', label: Text('服务器目录')),
                  ButtonSegment(value: 'upload', label: Text('上传 tar')),
                ],
                selected: {_type},
                onSelectionChanged: (value) =>
                    setState(() => _type = value.first),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _tag,
                decoration: const InputDecoration(
                  labelText: '镜像标签',
                  hintText: 'hampanel/app:latest',
                ),
              ),
              const SizedBox(height: 10),
              if (_type == 'git') ...[
                TextField(
                  controller: _url,
                  decoration: const InputDecoration(
                    labelText: 'Git 仓库 URL',
                    hintText: 'https://github.com/user/repo.git',
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _gitRef,
                        decoration: const InputDecoration(
                          labelText: '分支 / 标签（可选）',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _subdir,
                        decoration: const InputDecoration(labelText: '子目录（可选）'),
                      ),
                    ),
                  ],
                ),
              ] else if (_type == 'path') ...[
                TextField(
                  controller: _context,
                  decoration: const InputDecoration(
                    labelText: '服务器上的构建上下文目录',
                    hintText: '/srv/app',
                  ),
                ),
              ] else ...[
                TextField(
                  controller: _local,
                  decoration: const InputDecoration(labelText: '本机 tar 上下文路径'),
                ),
              ],
              const SizedBox(height: 10),
              TextField(
                controller: _dockerfile,
                decoration: const InputDecoration(
                  labelText: 'Dockerfile（可选，默认 Dockerfile）',
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (_tag.text.trim().isEmpty) return;
            Navigator.pop(
              context,
              _BuildRequest(
                type: _type,
                tag: _tag.text.trim(),
                url: _url.text.trim(),
                gitRef: _gitRef.text.trim(),
                subdir: _subdir.text.trim(),
                contextPath: _context.text.trim(),
                dockerfile: _dockerfile.text.trim(),
                localPath: _local.text.trim(),
              ),
            );
          },
          child: const Text('开始构建'),
        ),
      ],
    );
  }
}

String _buildName(String tag) {
  final buffer = StringBuffer();
  for (final code in tag.toLowerCase().codeUnits) {
    final ch = String.fromCharCode(code);
    buffer.write(RegExp(r'[a-z0-9_-]').hasMatch(ch) ? ch : '_');
  }
  final value = buffer.toString();
  if (value.isEmpty) return 'build';
  return RegExp(r'^[a-z0-9]').hasMatch(value) ? value : 'build_$value';
}
