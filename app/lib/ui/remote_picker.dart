import 'dart:io';

import 'package:material_ui/material_ui.dart';

import 'selection_toolbar.dart';

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
/// host (file system), the local machine, or expose a fixed tree built by the
/// caller (volumes, predefined mount points, ...).
///
/// The picker itself must not know which kind it is holding: it asks these
/// members for navigation, labels and selectability, so any tree works.
abstract class RemotePickerSource {
  String get title;

  /// Path shown when the picker opens with an empty path.
  String get root => '';

  /// Lists the children of [path]. [includeFiles] asks for files as well as
  /// directories; sources that have no notion of files ignore it.
  Future<List<RemotePickerEntry>> list(String path, {bool includeFiles = false});

  /// Parent of [path], or null at the top of the tree.
  String? parentOf(String path) => null;

  /// Breadcrumb labels from the root to [path].
  List<String> crumbsFor(String path) => path.isEmpty ? const [] : [path];

  /// Whether [path] itself can be confirmed rather than only navigated into.
  bool selectable(String path) => path.isNotEmpty;

  /// Whether this entry can be confirmed. Tree sources allow picking leaves;
  /// file-system sources allow files only when the caller asked for them.
  bool selectableEntry(RemotePickerEntry entry, {required bool allowFiles}) =>
      entry.isDirectory;
}

/// Walks directories on the remote host through `GET /api/v1/files`.
class HostDirectorySource extends RemotePickerSource {
  HostDirectorySource(this.api, {this.root = '/'});

  final ApiClient api;
  @override
  final String root;

  @override
  String get title => '选择远程目录';

  @override
  String? parentOf(String path) {
    final trimmed = path.isEmpty ? root : path;
    if (trimmed == '/' || trimmed.isEmpty) return null;
    final slash = trimmed.lastIndexOf('/');
    return slash <= 0 ? '/' : trimmed.substring(0, slash);
  }

  @override
  List<String> crumbsFor(String path) {
    final trimmed = path.isEmpty ? root : path;
    final parts = trimmed.split('/').where((part) => part.isNotEmpty);
    return ['/', ...parts];
  }

  @override
  bool selectableEntry(RemotePickerEntry entry, {required bool allowFiles}) =>
      entry.isDirectory || allowFiles;

  @override
  Future<List<RemotePickerEntry>> list(
    String path, {
    bool includeFiles = false,
  }) async {
    final target = path.isEmpty ? root : path;
    final json = await api.getJson('/api/v1/files', query: {'path': target});
    final map = json as Map<String, dynamic>? ?? const {};
    final entries =
        ((map['entries'] as List<dynamic>?) ?? const [])
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
          ..sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
    return entries;
  }
}

/// Walks the machine the client runs on. Local paths are a tree like any other,
/// so the same picker serves them: upload source, download destination, a local
/// tar file, an SSH private key.
class LocalDirectorySource extends RemotePickerSource {
  LocalDirectorySource({String? start});

  /// Where the picker opens when nothing is selected yet. Defaults to the home
  /// directory so the operator does not start at `/` every time.
  String? start;

  @override
  String get title => '选择本机路径';

  @override
  String get root {
    final preferred = start;
    if (preferred != null && preferred.isNotEmpty) return preferred;
    final home =
        Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (home != null && home.isNotEmpty) return home;
    return Platform.isWindows ? '' : '/';
  }

  @override
  String? parentOf(String path) {
    if (path.isEmpty) return null;
    final normalized = path.replaceAll(r'\', '/');
    final trimmed = normalized.length > 1 && normalized.endsWith('/')
        ? normalized.substring(0, normalized.length - 1)
        : normalized;
    final slash = trimmed.lastIndexOf('/');
    if (slash < 0) return null;
    // A drive root such as C:/ stays the top of its own tree.
    return slash == 0 ? (Platform.isWindows ? null : '/') : trimmed.substring(0, slash);
  }

  @override
  List<String> crumbsFor(String path) {
    if (path.isEmpty) return const [];
    final normalized = path.replaceAll(r'\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    return normalized.startsWith('/') ? ['/', ...parts] : parts.toList();
  }

  @override
  bool selectableEntry(RemotePickerEntry entry, {required bool allowFiles}) =>
      entry.isDirectory || allowFiles;

  @override
  Future<List<RemotePickerEntry>> list(
    String path, {
    bool includeFiles = false,
  }) async {
    final target = path.isEmpty ? root : path;
    if (target.isEmpty) return _windowsRoots();
    final entries = <RemotePickerEntry>[];
    await for (final entity in Directory(target).list(followLinks: false)) {
      final type = await FileSystemEntity.type(entity.path, followLinks: false);
      final isDirectory = type == FileSystemEntityType.directory;
      if (!isDirectory && !includeFiles) continue;
      final name = entity.path
          .split(RegExp(r'[/\\]'))
          .lastWhere((part) => part.isNotEmpty, orElse: () => entity.path);
      entries.add(
        RemotePickerEntry(
          name: name,
          path: entity.path,
          isDirectory: isDirectory,
        ),
      );
    }
    entries.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
    return entries;
  }

  /// Windows has no single root path, so the top level lists the drives.
  List<RemotePickerEntry> _windowsRoots() {
    final drives = <RemotePickerEntry>[];
    for (var code = 'A'.codeUnitAt(0); code <= 'Z'.codeUnitAt(0); code++) {
      final drive = '${String.fromCharCode(code)}:\\';
      if (Directory(drive).existsSync()) {
        drives.add(
          RemotePickerEntry(name: drive, path: drive, isDirectory: true),
        );
      }
    }
    return drives;
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
class TreePickerSource extends RemotePickerSource {
  TreePickerSource({required this.title, required this.nodes});

  @override
  final String title;
  final List<RemotePickerNode> nodes;

  @override
  Future<List<RemotePickerEntry>> list(
    String path, {
    bool includeFiles = false,
  }) async {
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

  @override
  String? parentOf(String path) {
    if (path.isEmpty) return null;
    final slash = path.lastIndexOf('/');
    return slash <= 0 ? '' : path.substring(0, slash);
  }

  @override
  List<String> crumbsFor(String path) {
    final labels = <String>[];
    var current = path;
    while (current.isNotEmpty) {
      labels.insert(0, labelOf(current));
      final slash = current.lastIndexOf('/');
      current = slash <= 0 ? '' : current.substring(0, slash);
    }
    return labels.isEmpty ? const ['全部'] : labels;
  }

  /// Whether the path itself can be confirmed rather than only navigated.
  @override
  bool selectable(String path) => _find(path)?.selectable ?? path.isEmpty;

  @override
  bool selectableEntry(RemotePickerEntry entry, {required bool allowFiles}) =>
      selectable(entry.path);

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
      final entries = await widget.source.list(
        path,
        includeFiles: widget.allowFiles,
      );
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

  List<String> get _crumbs => widget.source.crumbsFor(_path);

  void _up() {
    final parent = widget.source.parentOf(_path);
    if (parent != null) _load(parent);
  }

  String get _currentPath =>
      _path.isEmpty ? widget.source.root : _path;

  bool _selectable(String path) =>
      path.isNotEmpty && widget.source.selectable(path);

  bool _canSelectEntry(RemotePickerEntry entry) =>
      _selectable(entry.path) &&
      widget.source.selectableEntry(entry, allowFiles: widget.allowFiles);

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
                          for (
                            var index = 0;
                            index < crumbs.length;
                            index++
                          ) ...[
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
                Semantics(
                  liveRegion: true,
                  child: Text('已选择 ${_selected.length} 项'),
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
                          widget.allowFiles ? '这里没有子目录或文件' : '这里没有子目录',
                          style: TextStyle(fontSize: 12, color: hampanelMuted),
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
                                        const Icon(
                                          Icons.chevron_right,
                                          size: 16,
                                        ),
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
              if (widget.multiple)
                SelectionToolbar(
                  selected: _selected,
                  visible: _loading || _error != null
                      ? {}
                      : _entries
                            .where(_canSelectEntry)
                            .map((entry) => entry.path)
                            .toSet(),
                  onChanged: (paths) => setState(() {
                    _selected
                      ..clear()
                      ..addAll(paths);
                  }),
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

/// A text field for a path with a browse button that opens [showRemotePicker].
/// Use this instead of a bare TextField anywhere the user would otherwise have
/// to remember a path.
///
/// Pass [source] for any tree — the local disk, fixed nodes, or the remote host
/// — or [api] as shorthand for a [HostDirectorySource].
class RemotePathField extends StatelessWidget {
  const RemotePathField({
    super.key,
    this.api,
    this.source,
    required this.controller,
    required this.label,
    this.hintText,
    this.helperText,
    this.allowFiles = false,
    this.enabled = true,
    this.isDense = false,
    this.onPicked,
    this.onChanged,
    this.initialPath,
  }) : assert(
         api != null || source != null,
         'RemotePathField needs either api or source',
       );

  /// Remote host shorthand: a [HostDirectorySource] over [api].
  final ApiClient? api;

  /// Explicit tree; takes precedence, so local and fixed trees work too.
  final RemotePickerSource? source;
  final TextEditingController controller;
  final String label;
  final String? hintText;
  final String? helperText;

  /// Allow confirming a file, not only a directory.
  final bool allowFiles;
  final bool enabled;
  final bool isDense;
  final ValueChanged<String>? onPicked;

  /// Fires on manual edits too, so callers that gate a button on the value do
  /// not have to poll the controller.
  final ValueChanged<String>? onChanged;
  final String? initialPath;

  RemotePickerSource get _source =>
      source ?? HostDirectorySource(api!, root: initialPath ?? '/');

  Future<void> _pick(BuildContext context) async {
    final picked = await showRemotePicker(
      context,
      source: _source,
      initialPath: (initialPath ?? controller.text).trim(),
      allowFiles: allowFiles,
      confirmLabel: '选择',
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
      onChanged: onChanged,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        helperText: helperText,
        isDense: isDense,
        suffixIcon: IconButton(
          tooltip: allowFiles ? '浏览并选择文件' : '浏览并选择目录',
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

/// Single-line dialog for a path, with a browse button walking [source].
///
/// The plain [textInputDialog] forces the operator to remember a path by heart;
/// this is the same dialog with the picker attached. Any tree works, so it
/// serves the local disk as well as the remote host.
Future<String?> pathInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  required RemotePickerSource source,
  String initial = '',
  String confirmLabel = '确定',
  bool allowFiles = false,
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: DialogBody(
        maxWidth: 460,
        child: RemotePathField(
          source: source,
          controller: controller,
          label: label,
          allowFiles: allowFiles,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}
