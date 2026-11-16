import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/enrollment.dart';
import '../../core/host_store.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/enrollment_trust.dart';
import '../../ui/widgets.dart';

/// 多机管理：本机 SQLite 中的受管主机列表、别名与凭据 CRUD。
class HostsPage extends StatefulWidget {
  const HostsPage({super.key, required this.onSwitchHost});

  final Future<void> Function(HostRecord host) onSwitchHost;

  @override
  State<HostsPage> createState() => _HostsPageState();
}

class _HostsPageState extends State<HostsPage> {
  bool _busy = false;

  PanelSession get _session => PanelScope.of(context);
  HostStore get _hosts => _session.hosts;

  void _afterChange() {
    _session.refreshHosts();
    if (mounted) setState(() {});
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _add() async {
    final created = await showDialog<HostRecord>(
      context: context,
      builder: (_) => _HostEditDialog(store: _hosts),
    );
    if (created == null) return;
    _afterChange();
    if (created.id == _hosts.activeId) {
      await widget.onSwitchHost(created);
    } else {
      _toast('已添加主机 ${created.alias}');
    }
  }

  Future<void> _edit(HostRecord host) async {
    final updated = await showDialog<HostRecord>(
      context: context,
      builder: (_) => _HostEditDialog(store: _hosts, existing: host),
    );
    if (updated == null) return;
    _afterChange();
    if (updated.id == _hosts.activeId && !_sameCredentials(host, updated)) {
      await widget.onSwitchHost(updated);
    } else {
      _toast('已更新 ${updated.alias}');
    }
  }

  /// Alias-only edits keep the live session; swapping credentials requires a
  /// new API client, so only then is the host re-activated.
  bool _sameCredentials(HostRecord before, HostRecord after) =>
      jsonEncode(before.enrollment.toJson()) ==
      jsonEncode(after.enrollment.toJson());

  Future<void> _delete(HostRecord host) async {
    if (host.id == _hosts.activeId) {
      _toast('请先切换到其他主机，再删除当前主机');
      return;
    }
    final confirmed = await confirmDialog(
      context,
      title: '删除主机',
      message:
          '删除 ${host.alias}（${host.enrollment.endpoint}）？'
          '\n仅移除本地记录，不影响远端 daemon。',
      confirmLabel: '删除',
      danger: true,
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      _hosts.delete(host.id);
      _afterChange();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _activate(HostRecord host) async {
    setState(() => _busy = true);
    try {
      _hosts.setActive(host.id);
      _afterChange();
      await widget.onSwitchHost(host);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = _hosts.list();
    final activeId = _hosts.activeId;
    return Column(
      children: [
        PageHeader(
          title: '主机管理',
          subtitle: '多机别名与凭据，切换即时生效；凭据仅保存在本机数据库。',
          actions: [
            FilledButton.icon(
              onPressed: _busy ? null : _add,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新增主机'),
            ),
          ],
        ),
        Expanded(
          child: records.isEmpty
              ? const EmptyState(
                  icon: Icons.dns_outlined,
                  title: '还没有受管主机',
                  message: '新增主机并粘贴 enrollment JSON，或通过 SSH 安装自动导入。',
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  itemCount: records.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 14),
                  itemBuilder: (context, index) {
                    final host = records[index];
                    return _HostCard(
                      host: host,
                      active: host.id == activeId,
                      busy: _busy,
                      onActivate: () => _activate(host),
                      onEdit: () => _edit(host),
                      onDelete: () => _delete(host),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _HostCard extends StatelessWidget {
  const _HostCard({
    required this.host,
    required this.active,
    required this.busy,
    required this.onActivate,
    required this.onEdit,
    required this.onDelete,
  });

  final HostRecord host;
  final bool active;
  final bool busy;
  final Future<void> Function() onActivate;
  final Future<void> Function() onEdit;
  final Future<void> Function() onDelete;

  @override
  Widget build(BuildContext context) {
    final enrollment = host.enrollment;
    return PanelCard(
      title: host.alias,
      trailing: StatusPill(text: active ? '当前' : '备用', good: active),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _detail('端点', enrollment.endpoint),
          _detail('入口前缀', enrollment.entryPrefix),
          _detail('客户端 CN', enrollment.clientCn),
          _detail('CA 指纹', enrollment.caSha256),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!active)
                OutlinedButton.icon(
                  onPressed: busy ? null : onActivate,
                  icon: const Icon(Icons.swap_horiz, size: 15),
                  label: const Text('设为当前'),
                ),
              if (!active) const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: busy ? null : onEdit,
                icon: const Icon(Icons.edit_outlined, size: 15),
                label: const Text('编辑'),
              ),
              const Spacer(),
              IconButton(
                tooltip: '删除',
                onPressed: busy ? null : onDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                style: IconButton.styleFrom(foregroundColor: hampanelDanger),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _detail(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'DejaVu Sans Mono',
                fontSize: 11.5,
                color: hampanelInkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostEditDialog extends StatefulWidget {
  const _HostEditDialog({required this.store, this.existing});

  final HostStore store;
  final HostRecord? existing;

  @override
  State<_HostEditDialog> createState() => _HostEditDialogState();
}

class _HostEditDialogState extends State<_HostEditDialog> {
  late final TextEditingController _alias;
  late final TextEditingController _bundle;
  bool _activate = false;
  String? _error;
  bool _busy = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _alias = TextEditingController(text: widget.existing?.alias ?? '');
    _bundle = TextEditingController();
  }

  @override
  void dispose() {
    _alias.dispose();
    _bundle.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      Enrollment enrollment;
      final text = _bundle.text.trim();
      if (text.isNotEmpty) {
        enrollment = Enrollment.fromText(text);
        if (!mounted) return;
        final trusted = await confirmEnrollmentTrust(context, enrollment);
        if (!trusted) {
          if (mounted) setState(() => _busy = false);
          return;
        }
      } else if (_isEdit) {
        enrollment = widget.existing!.enrollment;
      } else {
        throw const FormatException('请粘贴 daemon 的 enroll.json');
      }
      final existing = widget.existing;
      final HostRecord result;
      if (existing == null) {
        result = widget.store.upsert(
          alias: _alias.text,
          enrollment: enrollment,
          activate: _activate,
        );
      } else {
        widget.store.updateEnrollment(
          existing.id,
          enrollment,
          alias: _alias.text,
        );
        if (text.isNotEmpty) {
          widget.store.trustPins(existing.id, enrollment);
        }
        result = widget.store.byId(existing.id)!;
        if (_activate) {
          widget.store.setActive(existing.id);
        }
      }
      if (mounted) Navigator.of(context, rootNavigator: true).pop(result);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    } catch (error) {
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_isEdit ? '编辑主机' : '新增主机'),
      content: DialogBody(
        maxWidth: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _alias,
                decoration: const InputDecoration(
                  labelText: '主机别名',
                  hintText: '例如 edge-node（留空则使用端点主机名）',
                ),
              ),
              const SizedBox(height: 14),
              if (!_isEdit || _bundle.text.isNotEmpty)
                Text(
                  'ENROLLMENT JSON',
                  style: TextStyle(
                    fontFamily: 'DejaVu Sans Mono',
                    fontSize: 10.5,
                    letterSpacing: 1,
                    color: hampanelMuted,
                  ),
                ),
              if (!_isEdit || _bundle.text.isNotEmpty)
                const SizedBox(height: 8),
              if (!_isEdit || _bundle.text.isNotEmpty)
                TextField(
                  controller: _bundle,
                  minLines: _isEdit ? 4 : 8,
                  maxLines: 12,
                  style: monospace,
                  decoration: InputDecoration(
                    hintStyle: monospace.copyWith(color: hampanelMuted),
                    hintText: _isEdit
                        ? '留空保持现有凭据'
                        : '{ "endpoint": "...", ... }',
                    alignLabelWithHint: true,
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                '凭据包含 CA、客户端证书与私钥，仅保存在本机 hosts 数据库。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
              if (!_isEdit) ...[
                const SizedBox(height: 10),
                CheckboxListTile(
                  value: _activate,
                  onChanged: (value) =>
                      setState(() => _activate = value ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    '保存后立即切换到该主机',
                    style: TextStyle(fontSize: 12.5),
                  ),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 6),
                ErrorBanner(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _busy ? null : _submit,
          icon: const Icon(Icons.save_outlined, size: 15),
          label: Text(_isEdit ? '保存' : '添加'),
        ),
      ],
    );
  }
}
