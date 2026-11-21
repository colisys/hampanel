import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../ui/remote_picker.dart';
import '../../core/models/docker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ContainerFilesDialog extends StatefulWidget {
  const ContainerFilesDialog({
    super.key,
    required this.api,
    required this.container,
  });

  final ApiClient api;
  final DockerContainer container;

  @override
  State<ContainerFilesDialog> createState() => _ContainerFilesDialogState();
}

class _ContainerFilesDialogState extends State<ContainerFilesDialog> {
  static const _root = '/';

  String _path = _root;
  List<_FileEntry> _entries = const [];
  String _raw = '';
  String? _error;
  bool _loading = true;

  ApiClient get _api => widget.api;

  String get _base => '/api/v1/docker/containers/${widget.container.id}/files';

  @override
  void initState() {
    super.initState();
    _load(_root);
  }

  Future<void> _load(String path) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson(_base, query: {'path': path});
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _path = map['path'] as String? ?? path;
        _entries = ((map['entries'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(_FileEntry.fromJson)
            .toList();
        _raw = map['raw'] as String? ?? '';
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

  String _join(String name) {
    if (_path == _root) return '/$name';
    return '$_path/$name';
  }

  void _goUp() {
    if (_path == _root) return;
    final trimmed = _path.endsWith('/')
        ? _path.substring(0, _path.length - 1)
        : _path;
    final index = trimmed.lastIndexOf('/');
    _load(index <= 0 ? _root : trimmed.substring(0, index));
  }

  Future<void> _open(_FileEntry entry) async {
    if (entry.isDirectory) {
      await _load(_join(entry.name));
      return;
    }
    try {
      final json = await _api.getJson(
        '$_base/content',
        query: {'path': _join(entry.name)},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      final encoding = map['encoding'] as String? ?? 'utf8';
      final content = map['content'] as String? ?? '';
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(entry.name),
          content: DialogBody(
            maxWidth: 860,
            maxHeight: 560,
            child: SingleChildScrollView(
              child: SelectableText(
                encoding == 'base64' ? '二进制文件，请下载后查看。' : content,
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

  Future<void> _mkdir() async {
    final name = await textInputDialog(context, title: '新建文件夹', label: '文件夹名称');
    if (name == null || name.trim().isEmpty) return;
    try {
      await _api.postJson('$_base/mkdir', {'path': _join(name.trim())});
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _rename(_FileEntry entry) async {
    final name = await textInputDialog(
      context,
      title: '重命名',
      label: '新名称',
      initial: entry.name,
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await _api.postJson('$_base/rename', {
        'from': _join(entry.name),
        'to': _join(name.trim()),
      });
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _delete(_FileEntry entry) async {
    final ok = await confirmDialog(
      context,
      title: '删除 ${entry.name}?',
      message: '该操作不可撤销。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      final json = await _api.postJson('$_base/delete', {
        'paths': [_join(entry.name)],
      });
      final map = json as Map<String, dynamic>;
      if (map['ok'] != true) {
        throw StateError(map['output'] as String? ?? '删除失败');
      }
      await _load(_path);
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _upload() async {
    final localPath = await pathInputDialog(
      context,
      title: '上传文件',
      label: '本机文件路径',
      source: LocalDirectorySource(),
      allowFiles: true,
      initial: Platform.environment['HOME'] ?? '',
    );
    if (localPath == null || localPath.trim().isEmpty) return;
    final file = File(localPath.trim());
    try {
      if (!await file.exists()) {
        _toast('本机文件不存在');
        return;
      }
      final bytes = await file.readAsBytes();
      final name = file.uri.pathSegments.last;
      await _api.uploadBytes('$_base/upload', {'path': _join(name)}, bytes);
      await _load(_path);
      _toast('已上传 $name');
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _download(_FileEntry entry) async {
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    final target = await pathInputDialog(
      context,
      title: '下载 ${entry.name}',
      label: '保存到本机路径',
      source: LocalDirectorySource(),
      allowFiles: true,
      initial: home.isEmpty ? entry.name : '$home/Downloads/${entry.name}',
    );
    if (target == null || target.trim().isEmpty) return;
    try {
      final bytes = await _api.downloadToBytes('$_base/download', {
        'path': _join(entry.name),
      });
      final file = File(target.trim());
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
      _toast('已保存到 ${file.path}');
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
    return AlertDialog(
      title: Text('文件 · ${widget.container.name}'),
      content: DialogBody(
        maxWidth: 900,
        maxHeight: 640,
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  tooltip: '上一级',
                  onPressed: _path == _root ? null : _goUp,
                  icon: const Icon(Icons.arrow_upward, size: 18),
                ),
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: hampanelBorder),
                    ),
                    child: Text(
                      _path,
                      overflow: TextOverflow.ellipsis,
                      style: monospace.copyWith(fontSize: 12),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: '刷新',
                  onPressed: () => _load(_path),
                  icon: const Icon(Icons.refresh, size: 18),
                ),
                IconButton(
                  tooltip: '上传',
                  onPressed: _upload,
                  icon: const Icon(Icons.upload_file, size: 18),
                ),
                IconButton(
                  tooltip: '新建文件夹',
                  onPressed: _mkdir,
                  icon: const Icon(Icons.create_new_folder_outlined, size: 18),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              ErrorBanner(message: _error!, onRetry: () => _load(_path)),
            ],
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const LoadingView()
                  : _entries.isEmpty
                  ? SingleChildScrollView(
                      child: SelectableText(
                        _raw.isEmpty ? '目录为空' : _raw,
                        style: monospace,
                      ),
                    )
                  : ListView.separated(
                      itemCount: _entries.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (context, index) {
                        final entry = _entries[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            entry.isDirectory
                                ? Icons.folder_outlined
                                : entry.symlink
                                ? Icons.link
                                : Icons.insert_drive_file_outlined,
                            size: 18,
                            color: entry.isDirectory
                                ? hampanelAccent
                                : hampanelMuted,
                          ),
                          title: Text(
                            entry.name,
                            style: monospace.copyWith(fontSize: 12),
                          ),
                          subtitle: Text(
                            '${entry.kind} · ${entry.sizeLabel} · ${entry.modified}',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: hampanelMuted,
                            ),
                          ),
                          onTap: () => _open(entry),
                          trailing: PopupMenuButton<String>(
                            icon: const Icon(Icons.more_horiz, size: 18),
                            onSelected: (value) {
                              switch (value) {
                                case 'open':
                                  _open(entry);
                                case 'rename':
                                  _rename(entry);
                                case 'download':
                                  _download(entry);
                                case 'delete':
                                  _delete(entry);
                              }
                            },
                            itemBuilder: (context) => const [
                              PopupMenuItem(value: 'open', child: Text('打开')),
                              PopupMenuItem(
                                value: 'rename',
                                child: Text('重命名'),
                              ),
                              PopupMenuItem(
                                value: 'download',
                                child: Text('下载'),
                              ),
                              PopupMenuItem(value: 'delete', child: Text('删除')),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

class _FileEntry {
  const _FileEntry({
    required this.name,
    required this.kind,
    required this.mode,
    required this.size,
    required this.modified,
    required this.symlink,
  });

  final String name;
  final String kind;
  final String mode;
  final int size;
  final String modified;
  final bool symlink;

  bool get isDirectory => kind == 'dir';

  String get sizeLabel {
    if (isDirectory) return '—';
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(1)} KB';
    return '${(size / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  factory _FileEntry.fromJson(Map<String, dynamic> json) => _FileEntry(
    name: json['name'] as String? ?? '',
    kind: json['kind'] as String? ?? '',
    mode: json['mode'] as String? ?? '',
    size: (json['size'] as num?)?.toInt() ?? 0,
    modified: json['modified'] as String? ?? '',
    symlink: json['symlink'] as bool? ?? false,
  );
}
