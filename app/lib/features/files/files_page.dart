import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/file_results.dart';
import '../../core/models/file_entry.dart';
import '../../core/models/recycle_entry.dart';
import '../../core/native_files.dart';
import '../../core/session.dart';
import '../../ui/code_editor.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'file_permissions_dialog.dart';
import '../recycle/recycle_page.dart';
import '../store/deploy_dialog.dart';

class FilesPage extends StatefulWidget {
  const FilesPage({super.key});

  @override
  State<FilesPage> createState() => _FilesPageState();
}

class _FilesPageState extends State<FilesPage> {
  final _pathController = TextEditingController(text: '/');
  List<FileEntry> _entries = const [];
  String _path = '/';
  String? _error;
  bool _loading = true;
  bool _deleting = false;
  int _loadId = 0;
  final _selectedPaths = <String>{};

  @override
  void initState() {
    super.initState();
    _bootstrapPath();
  }

  Future<void> _bootstrapPath() async {
    var initial = '/';
    try {
      final info = await _api.getJson('/api/v1/system');
      if (info is Map<String, dynamic> && info['platform'] == 'windows') {
        initial = 'C:\\';
      }
    } catch (_) {
      // fall back to the POSIX root
    }
    if (mounted && _loadId == 0) await _load(initial);
  }

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  ApiClient get _api => PanelScope.of(context).api;

  Future<void> _load(String path) async {
    final loadId = ++_loadId;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/files', query: {'path': path});
      final map = json as Map<String, dynamic>;
      final entries = ((map['entries'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FileEntry.fromJson)
          .toList();
      if (!mounted || loadId != _loadId) return;
      final listedPath = map['path'] as String? ?? path;
      final listedPaths = entries.map((entry) => entry.path).toSet();
      setState(() {
        if (listedPath != _path) _selectedPaths.clear();
        _selectedPaths.retainAll(listedPaths);
        _path = listedPath;
        _pathController.text = _path;
        _entries = entries;
        _loading = false;
      });
    } catch (error) {
      if (!mounted || loadId != _loadId) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  Future<void> _edit(FileEntry entry) async {
    try {
      final json = await _api.getJson(
        '/api/v1/files/content',
        query: {'path': entry.path},
      );
      final content = FileContent.fromJson(json as Map<String, dynamic>);
      content.requireEditable();
      if (!mounted) return;
      final edited = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => CodeEditorPage(
            title: entry.name,
            initialText: content.content,
            language: _codeLanguageForPath(entry.path),
            api: _api,
            filePath: entry.path,
          ),
        ),
      );
      if (edited == null || edited == content.content) return;
      await _api.putJson('/api/v1/files/content', {
        'path': entry.path,
        'content': edited,
      });
      _toast('已保存 ${entry.name}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  CodeLanguage _codeLanguageForPath(String path) {
    final name = path.toLowerCase();
    if (name.endsWith('.toml')) return CodeLanguage.toml;
    if (name.endsWith('.yaml') || name.endsWith('.yml')) {
      return CodeLanguage.yaml;
    }
    if (name.endsWith('.json')) return CodeLanguage.json;
    if (name.endsWith('.sh') || name.endsWith('.bash')) {
      return CodeLanguage.bash;
    }
    if (name.endsWith('.properties')) return CodeLanguage.properties;
    if (name.contains('nginx')) return CodeLanguage.nginx;
    if (name.endsWith('dockerfile') || name.endsWith('.dockerfile')) {
      return CodeLanguage.dockerfile;
    }
    if (name.endsWith('.conf') ||
        name.endsWith('.ini') ||
        name.endsWith('.service') ||
        name.endsWith('.socket')) {
      return CodeLanguage.ini;
    }
    return CodeLanguage.plain;
  }

  Future<void> _createFile() async {
    final name = await textInputDialog(context, title: '新建文件', label: '文件名');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _api.putJson('/api/v1/files/content', {
        'path': _join(name.trim()),
        'content': '',
      });
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _createFolder() async {
    final name = await textInputDialog(context, title: '新建目录', label: '目录名');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _api.postJson('/api/v1/files/mkdir', {
        'path': _join(name.trim()),
        'recursive': false,
      });
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _permissions(FileEntry entry) async {
    final api = _api;
    try {
      final json = await api.getJson(
        '/api/v1/files/meta',
        query: {'path': entry.path},
      );
      final meta = json as Map<String, dynamic>? ?? const {};
      if (meta['text'] != true) {
        _toast('暂不支持编辑二进制文件');
        return;
      }
      if (!mounted) return;
      final changed = await showDialog<bool>(
        context: context,
        builder: (_) => FilePermissionsDialog(
          api: api,
          path: entry.path,
          name: entry.name,
          meta: meta,
        ),
      );
      if (changed == true) {
        _toast('权限已更新');
        await _load(_path);
      }
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _rename(FileEntry entry) async {
    final name = await textInputDialog(
      context,
      title: '重命名',
      label: '新名称',
      initial: entry.name,
    );
    if (name == null || name.trim().isEmpty || name == entry.name) return;
    try {
      await _api.postJson('/api/v1/files/rename', {
        'from': entry.path,
        'to': _join(name.trim()),
      });
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _delete(FileEntry entry) => _deletePaths(
    [entry.path],
    title: '删除 ${entry.name}?',
    message: entry.isDir
        ? '目录及其内容会移动到回收站，可在「回收站」页面恢复。'
        : '文件会移动到回收站，可在「回收站」页面恢复。',
  );

  Future<void> _deleteSelected() => _deletePaths(
    _selectedPaths.toList(),
    title: '删除所选的 ${_selectedPaths.length} 项？',
    message: '所选文件和目录（含其内容）会移动到回收站，可在「回收站」页面恢复。',
  );

  Future<void> _deletePaths(
    List<String> paths, {
    required String title,
    required String message,
  }) async {
    if (_deleting || paths.isEmpty) return;
    final directory = _path;
    final ok = await confirmDialog(
      context,
      title: title,
      message: message,
      confirmLabel: '移入回收站',
      danger: true,
    );
    if (!mounted || !ok || _deleting) return;
    setState(() => _deleting = true);
    try {
      final result = await _api.postJson('/api/v1/files/delete', {
        'paths': paths,
      });
      if (!mounted) return;
      if (!_loading && _path == directory) await _load(directory);
      requireDeleted(result, paths);
      _toast('已移入回收站');
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
  }

  Widget _selectionControls(double horizontal) => Padding(
    padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 8),
    child: Wrap(
      spacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Semantics(
          liveRegion: true,
          child: Text('已选择 ${_selectedPaths.length} 项'),
        ),
        TextButton(
          onPressed: _deleting ||
                  _entries.every((entry) => _selectedPaths.contains(entry.path))
              ? null
              : () => setState(() {
                  _selectedPaths.addAll(_entries.map((entry) => entry.path));
                }),
          child: const Text('全选'),
        ),
        TextButton(
          onPressed: _deleting || _selectedPaths.isEmpty
              ? null
              : () => setState(_selectedPaths.clear),
          child: const Text('清空选择'),
        ),
        OutlinedButton.icon(
          onPressed: _deleting || _selectedPaths.isEmpty
              ? null
              : _deleteSelected,
          icon: const Icon(Icons.delete_outline, size: 16),
          label: const Text('移入回收站'),
        ),
      ],
    ),
  );

  Widget _selectionCheckbox(FileEntry entry) => Semantics(
    label: '选择 ${entry.name}',
    child: Checkbox(
      value: _selectedPaths.contains(entry.path),
      onChanged: _deleting
          ? null
          : (selected) => setState(() {
              if (selected == true) {
                _selectedPaths.add(entry.path);
              } else {
                _selectedPaths.remove(entry.path);
              }
            }),
    ),
  );

  Future<void> _versions(FileEntry entry) async {
    try {
      final json = await _api.getJson(
        '/api/v1/files/versions',
        query: {'path': entry.path},
      );
      final map = json as Map<String, dynamic>;
      final versions = ((map['versions'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(FileVersion.fromJson)
          .toList();
      if (!mounted) return;
      if (versions.isEmpty) {
        _toast('该文件暂无历史版本');
        return;
      }
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('${entry.name} 的历史版本'),
          content: DialogBody(
            maxWidth: 720,
            maxHeight: 460,
            child: ListView.separated(
              itemCount: versions.length,
              separatorBuilder: (_, _) => const Divider(),
              itemBuilder: (context, index) {
                final version = versions[index];
                return ListTile(
                  dense: true,
                  leading: const Icon(Icons.history, size: 18),
                  title: Text(
                    formatDateTime(version.createdAt),
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  subtitle: Text(
                    formatBytes(version.size),
                    style: const TextStyle(fontSize: 11),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () => _viewVersion(entry, version),
                        child: const Text('查看'),
                      ),
                      FilledButton(
                        onPressed: () async {
                          Navigator.pop(dialogContext);
                          await _restoreVersion(entry, version);
                        },
                        child: const Text('恢复'),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('关闭'),
            ),
          ],
        ),
      );
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _viewVersion(FileEntry entry, FileVersion version) async {
    try {
      final json = await _api.getJson(
        '/api/v1/files/versions/content',
        query: {'path': entry.path, 'id': version.id},
      );
      final map = json as Map<String, dynamic>;
      final encoding = map['encoding'] as String? ?? 'utf8';
      final content = map['content'] as String? ?? '';
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('版本 ${formatDateTime(version.createdAt)}'),
          content: DialogBody(
            maxWidth: 820,
            maxHeight: 520,
            child: SingleChildScrollView(
              child: SelectableText(
                encoding == 'utf8'
                    ? content
                    : '二进制版本，无法预览（大小 ${formatBytes(version.size)}）',
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

  Future<void> _restoreVersion(FileEntry entry, FileVersion version) async {
    final ok = await confirmDialog(
      context,
      title: '恢复历史版本？',
      message:
          '当前文件内容会先保存为新的历史版本，然后恢复为 ${formatDateTime(version.createdAt)} 的内容。',
      confirmLabel: '恢复',
    );
    if (!ok) return;
    try {
      final json = await _api.postJson('/api/v1/files/versions/restore', {
        'path': entry.path,
        'id': version.id,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(context, '恢复失败', map['output'] as String? ?? '');
      } else {
        _toast('历史版本已恢复');
      }
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _upload() async {
    if (NativeFiles.supported) {
      try {
        final picked = await NativeFiles.pick();
        if (picked == null) return;
        await _api.uploadBytes('/api/v1/files/upload', {
          'path': _join(picked.name),
        }, picked.bytes);
        await _load(_path);
        _toast('上传完成');
      } catch (error) {
        _toast(describeError(error));
      }
      return;
    }
    final localPath = await textInputDialog(
      context,
      title: '上传文件',
      label: '本地文件绝对路径',
      confirmLabel: '上传',
    );
    if (localPath == null || localPath.trim().isEmpty) return;
    final name = localPath.split(RegExp(r'[/\\]')).last;
    try {
      await _api.uploadFromFile('/api/v1/files/upload', {
        'path': _join(name),
      }, localPath.trim());
      await _load(_path);
      _toast('上传完成');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _download(FileEntry entry) async {
    if (NativeFiles.supported) {
      try {
        final bytes = await _api.downloadToBytes('/api/v1/files/download', {
          'path': entry.path,
        });
        final saved = await NativeFiles.save(entry.name, bytes);
        _toast(saved ? '已保存' : '已取消保存');
      } catch (error) {
        _toast(describeError(error));
      }
      return;
    }
    final target = await textInputDialog(
      context,
      title: '下载 ${entry.name}',
      label: '保存到本地路径',
      initial: entry.name,
      confirmLabel: '下载',
    );
    if (target == null || target.trim().isEmpty) return;
    try {
      final file = await _api.downloadToFile('/api/v1/files/download', {
        'path': entry.path,
      }, target.trim());
      _toast('已保存到 ${file.path}');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  String _join(String name) {
    final separator = _path.contains('\\') ? '\\' : '/';
    if (_path.endsWith('/') || _path.endsWith('\\')) return '$_path$name';
    return '$_path$separator$name';
  }

  String get _parent {
    final normalized = _path.replaceAll('\\', '/');
    if (normalized == '/' || normalized.isEmpty) return _path;
    final trimmed = normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final index = trimmed.lastIndexOf('/');
    if (index <= 0) return '/';
    final parent = trimmed.substring(0, index);
    return parent.isEmpty ? '/' : parent;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openRecycle() async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => RecyclePage(api: _api)),
    );
    if (mounted) _load(_path);
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final horizontal = compact ? 12.0 : 24.0;
    return Column(
      children: [
        PageHeader(
          title: '文件',
          actions: [PageRefreshButton(onPressed: () => _load(_path))],
        ),
        if (!compact)
          Padding(
            padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: _createFolder,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                  label: const Text('新建目录'),
                ),
                OutlinedButton.icon(
                  onPressed: _createFile,
                  icon: const Icon(Icons.note_add_outlined, size: 16),
                  label: const Text('新建文件'),
                ),
                OutlinedButton.icon(
                  onPressed: _upload,
                  icon: const Icon(Icons.upload_file_outlined, size: 16),
                  label: const Text('上传'),
                ),
                OutlinedButton.icon(
                  onPressed: _openRecycle,
                  icon: const Icon(Icons.delete_outline, size: 16),
                  label: const Text('回收站'),
                ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 10),
          child: Row(
            children: [
              IconButton(
                tooltip: '上一级',
                onPressed: () => _load(_parent),
                icon: const Icon(Icons.arrow_upward, size: 18),
              ),
              const SizedBox(width: 2),
              Expanded(
                child: TextField(
                  controller: _pathController,
                  style: monospace,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.folder_outlined, size: 17),
                  ),
                  onSubmitted: _load,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: '刷新',
                onPressed: () => _load(_path),
                icon: const Icon(Icons.refresh, size: 19),
              ),
            ],
          ),
        ),
        if (_error != null)
          ErrorBanner(message: _error!, onRetry: () => _load(_path)),
        if (!_loading && _error == null && _entries.isNotEmpty)
          _selectionControls(horizontal),
        Expanded(
          child: _loading
              ? const LoadingView()
              : Padding(
                  padding: EdgeInsets.fromLTRB(horizontal, 0, horizontal, 24),
                  child: Card(
                    child: _entries.isEmpty
                        ? EmptyState(
                            icon: Icons.folder_off_outlined,
                            title: '目录为空',
                            message: '使用底部操作创建文件或上传内容。',
                          )
                        : compact
                        ? _compactFileList()
                        : Column(
                            children: [
                              _headerRow(),
                              Divider(),
                              Expanded(
                                child: ListView.separated(
                                  itemCount: _entries.length,
                                  separatorBuilder: (_, _) =>
                                      Divider(indent: 16, endIndent: 16),
                                  itemBuilder: (context, index) =>
                                      _fileRow(_entries[index]),
                                ),
                              ),
                            ],
                          ),
                  ),
                ),
        ),
        if (compact)
          ActionDock(
            actions: [
              ActionDockItem(
                icon: Icons.create_new_folder_outlined,
                label: '新建目录',
                onPressed: _createFolder,
              ),
              ActionDockItem(
                icon: Icons.note_add_outlined,
                label: '新建文件',
                onPressed: _createFile,
              ),
              ActionDockItem(
                icon: Icons.upload_file_outlined,
                label: '上传',
                onPressed: _upload,
              ),
              ActionDockItem(
                icon: Icons.delete_outline,
                label: '回收站',
                onPressed: _openRecycle,
              ),
            ],
          ),
      ],
    );
  }

  Widget _compactFileList() {
    return ListView.separated(
      itemCount: _entries.length,
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) => _compactFileRow(_entries[index]),
    );
  }

  Widget _compactFileRow(FileEntry entry) {
    final icon = entry.isDir
        ? Icons.folder_outlined
        : entry.symlink
        ? Icons.link
        : Icons.description_outlined;
    final color = entry.isDir ? hampanelAccent : hampanelMuted;
    return InkWell(
      onTap: () => entry.isDir ? _load(entry.path) : _edit(entry),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 9, 4, 9),
        child: Row(
          children: [
            _selectionCheckbox(entry),
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12.5),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.owner.isEmpty
                        ? entry.mode
                        : '${entry.owner}:${entry.group} · ${entry.mode}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monospace.copyWith(
                      fontSize: 10.5,
                      color: hampanelMuted,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '${entry.isDir ? '目录' : formatBytes(entry.size)}'
                    ' · ${formatDateTime(entry.modifiedMs)}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: hampanelMuted),
                  ),
                ],
              ),
            ),
            _fileMenu(entry),
          ],
        ),
      ),
    );
  }

  Widget _fileMenu(FileEntry entry) {
    return PopupMenuButton<String>(
      icon: const Icon(Icons.more_horiz, size: 18),
      onSelected: (value) {
        switch (value) {
          case 'edit':
            _edit(entry);
          case 'versions':
            _versions(entry);
          case 'permissions':
            _permissions(entry);
          case 'rename':
            _rename(entry);
          case 'download':
            _download(entry);
          case 'delete':
            _delete(entry);
        }
      },
      itemBuilder: (context) => [
        if (!entry.isDir) const PopupMenuItem(value: 'edit', child: Text('编辑')),
        if (!entry.isDir)
          const PopupMenuItem(value: 'versions', child: Text('历史版本')),
        const PopupMenuItem(value: 'permissions', child: Text('权限')),
        const PopupMenuItem(value: 'rename', child: Text('重命名')),
        if (!entry.isDir)
          const PopupMenuItem(value: 'download', child: Text('下载')),
        PopupMenuItem(
          value: 'delete',
          enabled: !_deleting,
          child: const Text('删除'),
        ),
      ],
    );
  }

  Widget _headerRow() {
    final style = TextStyle(fontSize: 11, color: hampanelMuted);
    return Padding(
      padding: EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          SizedBox(width: 66),
          SizedBox(width: 10),
          Expanded(flex: 5, child: Text('名称', style: style)),
          Expanded(flex: 2, child: Text('大小', style: style)),
          Expanded(flex: 3, child: Text('用户/组', style: style)),
          Expanded(flex: 2, child: Text('权限', style: style)),
          Expanded(flex: 3, child: Text('修改时间', style: style)),
          SizedBox(width: 40),
        ],
      ),
    );
  }

  Widget _fileRow(FileEntry entry) {
    final icon = entry.isDir
        ? Icons.folder_outlined
        : entry.symlink
        ? Icons.link
        : Icons.description_outlined;
    final color = entry.isDir ? hampanelAccent : hampanelMuted;
    return InkWell(
      onTap: () => entry.isDir ? _load(entry.path) : _edit(entry),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            _selectionCheckbox(entry),
            Icon(icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(
              flex: 5,
              child: Text(
                entry.name,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontSize: 12.5),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(
                entry.isDir ? '-' : formatBytes(entry.size),
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                entry.owner.isEmpty ? '—' : '${entry.owner}:${entry.group}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
            ),
            Expanded(
              flex: 2,
              child: Text(entry.mode, style: monospace.copyWith(fontSize: 11)),
            ),
            Expanded(
              flex: 3,
              child: Text(
                formatDateTime(entry.modifiedMs),
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
            ),
            _fileMenu(entry),
          ],
        ),
      ),
    );
  }
}
