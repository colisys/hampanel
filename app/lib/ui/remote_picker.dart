import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/models/file_entry.dart';
import 'theme.dart';
import 'widgets.dart';

/// One selectable row in a [RemotePickerSource].
class RemotePickerEntry {
  const RemotePickerEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.subtitle = '',
  });

  final String name;
  final String path;
  final bool isDirectory;
  final String subtitle;
}

/// A hierarchy the picker can walk. Implementations may talk to the remote
/// host (file system) or expose a fixed tree built by the caller (volumes,
/// predefined mount points, ...).
abstract class RemotePickerSource {
  String get title;

  Future<List<RemotePickerEntry>> list(String path);
}

/// Walks directories on the remote host through `GET /api/v1/files`.
class HostDirectorySource implements RemotePickerSource {
  HostDirectorySource(this.api, {this.root = '/'});

  final ApiClient api;
  final String root;

  @override
  String get title => '选择远程目录';

  @override
  Future<List<RemotePickerEntry>> list(String path, {bool includeFiles = false}) async {
    final target = path.isEmpty ? root : path;
    final json = await api.getJson('/api/v1/files', query: {'path': target});
    final map = json as Map<String, dynamic>? ?? const {};
    final entries = ((map['entries'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(FileEntry.fromJson)
        .where((entry) => includeFiles || entry.isDir)
        .map(
          (entry) => RemotePickerEntry(
            name: entry.name,
            path: entry.path,
            isDirectory: entry.isDir,
            subtitle: entry.mode,
          ),
        )
        .toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return entries;
  }
}

/// One node of a caller-supplied tree.
class RemotePickerNode {
  const RemotePickerNode({
    required this.name,
    required this.path,
    this.subtitle = '',
    this.children = const [],
    this.selectable = true,
  });

  final String name;
  final String path;
  final String subtitle;
  final List<RemotePickerNode> children;
  final bool selectable;
}

/// Fixed tree source. Useful for volumes or any non-file selection.
class TreePickerSource implements RemotePickerSource {
  TreePickerSource({required this.title, required this.nodes});

  @override
  final String title;
  final List<RemotePickerNode> nodes;

  @override
  Future<List<RemotePickerEntry>> list(String path) async {
    final children = path.isEmpty ? nodes : _find(path)?.children ?? const [];
    return [
      for (final child in children)
        RemotePickerEntry(
          name: child.name,
          path: child.path,
          isDirectory: child.children.isNotEmpty,
          subtitle: child.subtitle,
        ),
    ];
  }

  /// Whether the path itself can be confirmed rather than only navigated.
  bool selectable(String path) => _find(path)?.selectable ?? path.isEmpty;

  /// Human-readable name for a tree path.
  String labelOf(String path) {
    final node = _find(path);
    return node?.name ?? path;
  }

  RemotePickerNode? _find(String path) {
    RemotePickerNode? walk(List<RemotePickerNode> nodes) {
      for (final node in nodes) {
        if (node.path == path) return node;
        final found = walk(node.children);
        if (found != null) return found;
      }
      return null;
    }

    return walk(nodes);
  }
}

/// Opens the picker and returns the selected path, or null when cancelled.
Future<String?> showRemotePicker(
  BuildContext context, {
  required RemotePickerSource source,
  String? initialPath,
  bool allowFiles = false,
  String confirmLabel = '选择',
}) {
  return showDialog<String>(
    context: context,
    builder: (context) => _RemotePickerDialog<String>(
      source: source,
      initialPath: initialPath ?? '',
      allowFiles: allowFiles,
      confirmLabel: confirmLabel,
      result: (paths) => paths.single,
    ),
  );
}

Future<List<String>?> showRemoteMultiPicker(
  BuildContext context, {
  required RemotePickerSource source,
  String? initialPath,
  bool allowFiles = false,
  String confirmLabel = '选择',
}) {
  return showDialog<List<String>>(
    context: context,
    builder: (context) => _RemotePickerDialog<List<String>>(
      source: source,
      initialPath: initialPath ?? '',
      allowFiles: allowFiles,
      confirmLabel: confirmLabel,
      multiple: true,
      result: List<String>.unmodifiable,
    ),
  );
}

class _RemotePickerDialog<T> extends StatefulWidget {
  const _RemotePickerDialog({
    required this.source,
    required this.initialPath,
    required this.allowFiles,
    required this.confirmLabel,
    required this.result,
    this.multiple = false,
  });

  final RemotePickerSource source;
  final String initialPath;
  final bool allowFiles;
  final String confirmLabel;
  final bool multiple;
  final T Function(Iterable<String>) result;

  @override
  State<_RemotePickerDialog<T>> createState() => _RemotePickerDialogState<T>();
}

class _RemotePickerDialogState<T> extends State<_RemotePickerDialog<T>> {
  final _selected = <String>{};
  late String _path = widget.initialPath;
  List<RemotePickerEntry> _entries = const [];
  bool _loading = true;
  int _loadId = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load(_path);
  }

  Future<void> _load(String path) async {
    final loadId = ++_loadId;
    setState(() {
      _path = path;
      _loading = true;
      _error = null;
    });
    try {
      final source = widget.source;
      final entries = source is HostDirectorySource
          ? await source.list(path, includeFiles: widget.allowFiles)
          : await source.list(path);
      if (!mounted || loadId != _loadId) return;
      setState(() {
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

  List<String> get _crumbs {
    final source = widget.source;
    if (source is HostDirectorySource) {
      final trimmed = _path.isEmpty ? source.root : _path;
      final parts = trimmed.split('/').where((part) => part.isNotEmpty);
      return ['/', ...parts];
    }
    if (source is TreePickerSource) {
      final labels = <String>[];
      var current = _path;
      while (current.isNotEmpty) {
        labels.insert(0, source.labelOf(current));
        final slash = current.lastIndexOf('/');
        current = slash <= 0 ? '' : current.substring(0, slash);
      }
      return labels.isEmpty ? const ['全部'] : labels;
    }
    return [_path];
  }

  void _up() {
    final source = widget.source;
    if (source is HostDirectorySource) {
      final trimmed = _path.isEmpty ? source.root : _path;
      if (trimmed == '/' || trimmed.isEmpty) return;
      final slash = trimmed.lastIndexOf('/');
      _load(slash <= 0 ? '/' : trimmed.substring(0, slash));
      return;
    }
    if (source is TreePickerSource) {
      if (_path.isEmpty) return;
      final slash = _path.lastIndexOf('/');
      _load(slash <= 0 ? '' : _path.substring(0, slash));
    }
  }

  String get _currentPath {
    final source = widget.source;
    return source is HostDirectorySource && _path.isEmpty ? source.root : _path;
  }

  bool _selectable(String path) {
    final source = widget.source;
    if (source is TreePickerSource) {
      return path.isNotEmpty && source.selectable(path);
    }
    return path.isNotEmpty;
  }

  bool _canSelectEntry(RemotePickerEntry entry) =>
      _selectable(entry.path) &&
      (entry.isDirectory ||
          widget.allowFiles ||
          widget.source is TreePickerSource);

  void _toggle(String path) {
    setState(() {
      if (!_selected.remove(path)) _selected.add(path);
    });
  }

  Widget _checkbox(String path, String label) => Semantics(
    label: label,
    child: Checkbox(
      value: _selected.contains(path),
      onChanged: (_) => _toggle(path),
    ),
  );

  void _finish(Iterable<String> paths) {
    Navigator.of(context).pop<T>(widget.result(paths));
  }

  @override
  Widget build(BuildContext context) {
    final crumbs = _crumbs;
    return AlertDialog(
      title: Text(widget.source.title),
      content: DialogBody(
        maxWidth: 560,
        maxHeight: 520,
        child: SizedBox(
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  IconButton(
                    tooltip: '上一级',
                    onPressed: _path.isEmpty ? null : _up,
                    icon: const Icon(Icons.arrow_upward, size: 18),
                    visualDensity: VisualDensity.compact,
                  ),
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (var index = 0; index < crumbs.length; index++) ...[
                            if (index > 0)
                              Icon(
                                Icons.chevron_right,
                                size: 14,
                                color: hampanelMuted,
                              ),
                            Text(
                              crumbs[index],
                              style: const TextStyle(fontSize: 11.5),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (widget.multiple)
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text('已选择 ${_selected.length} 项'),
                    ),
                    TextButton(
                      onPressed: _selected.isEmpty
                          ? null
                          : () => setState(_selected.clear),
                      child: const Text('清空选择'),
                    ),
                  ],
                ),
              const Divider(height: 10),
              Expanded(
                child: _loading
                    ? const LoadingView()
                    : _error != null
                    ? ErrorBanner(message: _error!, onRetry: () => _load(_path))
                    : _entries.isEmpty
                    ? Center(
                        child: Text(
                          widget.allowFiles
                              ? '这里没有子目录或文件'
                              : '这里没有子目录',
                          style: TextStyle(
                            fontSize: 12,
                            color: hampanelMuted,
                          ),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _entries.length,
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return ListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            leading: Icon(
                              entry.isDirectory
                                  ? Icons.folder_outlined
                                  : Icons.insert_drive_file_outlined,
                              size: 18,
                              color: entry.isDirectory
                                  ? hampanelAccent
                                  : hampanelMuted,
                            ),
                            title: Text(
                              entry.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12.5),
                            ),
                            subtitle: entry.subtitle.isEmpty
                                ? null
                                : Text(
                                    entry.subtitle,
                                    style: TextStyle(
                                      fontSize: 10.5,
                                      color: hampanelMuted,
                                    ),
                                  ),
                            trailing: widget.multiple && _canSelectEntry(entry)
                                ? Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _checkbox(entry.path, '选择 ${entry.name}'),
                                      if (entry.isDirectory)
                                        const Icon(Icons.chevron_right, size: 16),
                                    ],
                                  )
                                : entry.isDirectory
                                ? const Icon(Icons.chevron_right, size: 16)
                                : null,
                            onTap: entry.isDirectory
                                ? () => _load(entry.path)
                                : !_canSelectEntry(entry)
                                ? null
                                : widget.multiple
                                ? () => _toggle(entry.path)
                                : () => _finish([entry.path]),
                          );
                        },
                      ),
              ),
              if (widget.multiple &&
                  !_loading &&
                  _error == null &&
                  _selectable(_currentPath))
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text('选择当前位置'),
                  value: _selected.contains(_currentPath),
                  onChanged: (_) => _toggle(_currentPath),
                ),
              if (!_loading && _error == null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    _path.isEmpty ? '根目录' : _path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 10.5,
                      color: hampanelMuted,
                      fontFamily: 'monospace',
                    ),
                  ),
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
          onPressed: widget.multiple
              ? (_selected.isEmpty ? null : () => _finish(_selected))
              : (!_loading && _error == null && _selectable(_currentPath)
                    ? () => _finish([_currentPath])
                    : null),
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

/// A text field for a remote host path with a browse button that opens
/// [showRemotePicker]. Use this instead of a bare TextField anywhere the user
/// would otherwise have to remember a server-side path.
class RemotePathField extends StatelessWidget {
  const RemotePathField({
    super.key,
    required this.api,
    required this.controller,
    required this.label,
    this.hintText,
    this.helperText,
    this.allowFiles = false,
    this.enabled = true,
    this.isDense = false,
    this.onPicked,
    this.initialPath,
  });

  final ApiClient api;
  final TextEditingController controller;
  final String label;
  final String? hintText;
  final String? helperText;

  /// Allow confirming a file, not only a directory.
  final bool allowFiles;
  final bool enabled;
  final bool isDense;
  final ValueChanged<String>? onPicked;
  final String? initialPath;

  Future<void> _pick(BuildContext context) async {
    final picked = await showRemotePicker(
      context,
      source: HostDirectorySource(api),
      initialPath: (initialPath ?? controller.text).trim(),
      allowFiles: allowFiles,
      confirmLabel: allowFiles ? '选择' : '使用该目录',
    );
    if (picked == null) return;
    controller.text = picked;
    onPicked?.call(picked);
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        helperText: helperText,
        isDense: isDense,
        suffixIcon: IconButton(
          tooltip: allowFiles ? '从远程主机选择文件' : '从远程主机选择目录',
          visualDensity: VisualDensity.compact,
          onPressed: enabled ? () => _pick(context) : null,
          icon: Icon(
            allowFiles
                ? Icons.insert_drive_file_outlined
                : Icons.folder_open_outlined,
            size: 18,
          ),
        ),
      ),
    );
  }
}
