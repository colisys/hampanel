import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// Edits the classic nine permission bits plus owner and group. The metadata
/// comes from `/api/v1/files/meta`, which runs `file(1)` on the host.
class FilePermissionsDialog extends StatefulWidget {
  const FilePermissionsDialog({
    super.key,
    required this.api,
    required this.path,
    required this.name,
    required this.meta,
  });

  final ApiClient api;
  final String path;
  final String name;
  final Map<String, dynamic> meta;

  @override
  State<FilePermissionsDialog> createState() => _FilePermissionsDialogState();
}

class _FilePermissionsDialogState extends State<FilePermissionsDialog> {
  late int _bits =
      (widget.meta['mode_bits'] as num?)?.toInt() ?? 0x1A4;
  late int? _uid = (widget.meta['uid'] as num?)?.toInt();
  late int? _gid = (widget.meta['gid'] as num?)?.toInt();
  List<Map<String, dynamic>> _users = const [];
  List<Map<String, dynamic>> _groups = const [];
  bool _loadingAccounts = true;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
  }

  Future<void> _loadAccounts() async {
    try {
      final json = await widget.api.getJson('/api/v1/files/accounts');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _users = ((map['users'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _groups = ((map['groups'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .toList();
        _loadingAccounts = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loadingAccounts = false;
      });
    }
  }

  String get _symbolic {
    String part(int shift) {
      final bits = (_bits >> shift) & 0x7;
      return '${bits & 4 != 0 ? 'r' : '-'}'
          '${bits & 2 != 0 ? 'w' : '-'}'
          '${bits & 1 != 0 ? 'x' : '-'}';
    }

    return '${part(6)}${part(3)}${part(0)}';
  }

  String get _octal => (_bits & 0xFFF).toRadixString(8).padLeft(4, '0');

  void _toggle(int shift, int flag, bool value) {
    final bit = 1 << (shift + flag);
    setState(() {
      _bits = value ? _bits | bit : _bits & ~bit;
    });
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.api.postJson('/api/v1/files/permissions', {
        'path': widget.path,
        'mode': _bits,
        'uid': _uid,
        'gid': _gid,
      });
      if (!mounted) return;
      Navigator.of(context).pop(true);
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
    final mime = widget.meta['mime'] as String? ?? '';
    final kind = widget.meta['kind'] as String? ?? '';
    return AlertDialog(
      title: Text('权限 · ${widget.name}'),
      content: DialogBody(
        maxWidth: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                mime.isEmpty ? kind : '$kind · $mime',
                style: TextStyle(fontSize: 11, color: hampanelMuted),
              ),
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: hampanelSurfaceAlt,
                  border: Border.all(color: hampanelBorder),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Row(
                  children: [
                    Text(
                      _symbolic,
                      style: monospace.copyWith(fontSize: 14),
                    ),
                    const Spacer(),
                    Text(
                      _octal,
                      style: monospace.copyWith(
                        fontSize: 12,
                        color: hampanelMuted,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              _permissionGrid(),
              const SizedBox(height: 14),
              FormRow(
                children: [
                  DropdownButtonFormField<int>(
                    initialValue: _uid,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '用户',
                      isDense: true,
                    ),
                    items: [
                      if (_uid != null &&
                          !_users.any((user) => (user['id'] as num?)?.toInt() == _uid))
                        DropdownMenuItem(
                          value: _uid,
                          child: Text(
                            '${widget.meta['owner'] ?? _uid} ($_uid)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      for (final user in _users)
                        DropdownMenuItem(
                          value: (user['id'] as num?)?.toInt() ?? 0,
                          child: Text(
                            '${user['name']} (${user['id']})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _loadingAccounts
                        ? null
                        : (value) => setState(() => _uid = value),
                  ),
                  DropdownButtonFormField<int>(
                    initialValue: _gid,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '用户组',
                      isDense: true,
                    ),
                    items: [
                      if (_gid != null &&
                          !_groups.any((group) => (group['id'] as num?)?.toInt() == _gid))
                        DropdownMenuItem(
                          value: _gid,
                          child: Text(
                            '${widget.meta['group'] ?? _gid} ($_gid)',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      for (final group in _groups)
                        DropdownMenuItem(
                          value: (group['id'] as num?)?.toInt() ?? 0,
                          child: Text(
                            '${group['name']} (${group['id']})',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: _loadingAccounts
                        ? null
                        : (value) => setState(() => _gid = value),
                  ),
                ],
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 11.5, color: hampanelDanger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }

  Widget _permissionGrid() {
    Widget header(String label) => SizedBox(
      width: 58,
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 11, color: hampanelMuted),
      ),
    );

    Widget row(String label, int shift) {
      Widget box(int flag) => SizedBox(
        width: 58,
        child: Center(
          child: Checkbox(
            value: (_bits >> (shift + flag)) & 1 != 0,
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            onChanged: (value) => _toggle(shift, flag, value ?? false),
          ),
        ),
      );

      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Text(label, style: const TextStyle(fontSize: 12.5)),
            ),
            box(2),
            box(1),
            box(0),
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border.all(color: hampanelBorder),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const Expanded(child: SizedBox()),
              header('读'),
              header('写'),
              header('执行'),
            ],
          ),
          const Divider(height: 10),
          row('用户（owner）', 6),
          row('用户组（group）', 3),
          row('其他（other）', 0),
        ],
      ),
    );
  }
}
