import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/firewall.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class FirewallPage extends StatefulWidget {
  const FirewallPage({super.key});

  @override
  State<FirewallPage> createState() => _FirewallPageState();
}

class _FirewallPageState extends State<FirewallPage> {
  FirewallStatus? _status;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  ApiClient get _api => PanelScope.of(context).api;

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/firewall');
      if (!mounted) return;
      setState(() {
        _status = FirewallStatus.fromJson(json as Map<String, dynamic>);
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

  Future<void> _addRule() async {
    final portController = TextEditingController();
    final fromController = TextEditingController();
    final commentController = TextEditingController();
    var action = 'allow';

    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新增防火墙规则'),
          content: DialogBody(
            maxWidth: 480,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: action,
                  decoration: const InputDecoration(labelText: '动作'),
                  items: const [
                    DropdownMenuItem(value: 'allow', child: Text('允许')),
                    DropdownMenuItem(value: 'deny', child: Text('拒绝')),
                    DropdownMenuItem(value: 'limit', child: Text('限速')),
                  ],
                  onChanged: (value) =>
                      setDialogState(() => action = value ?? 'allow'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: portController,
                  decoration: const InputDecoration(
                    labelText: '端口',
                    hintText: '80 或 443/tcp',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: fromController,
                  decoration: const InputDecoration(
                    labelText: '来源（可选）',
                    hintText: '10.0.0.0/8',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: commentController,
                  decoration: const InputDecoration(labelText: '备注（可选）'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('添加'),
            ),
          ],
        ),
      ),
    );

    if (submitted == true) {
      try {
        await _api.postJson('/api/v1/firewall/rules', {
          'action': action,
          'port': portController.text.trim(),
          'from': fromController.text.trim(),
          'comment': commentController.text.trim(),
        });
        await _load();
      } catch (error) {
        _toast(describeError(error));
      }
    }

    portController.dispose();
    fromController.dispose();
    commentController.dispose();
  }

  Future<void> _deleteRule(FirewallRule rule) async {
    final ok = await confirmDialog(
      context,
      title: '删除规则?',
      message: rule.raw,
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.postJson('/api/v1/firewall/rules/delete', {'id': rule.id});
      await _load();
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
    final status = _status;
    return Column(
      children: [
        PageHeader(
          title: '防火墙',
          subtitle: status == null ? '正在读取规则' : '${status.rules.length} 条规则',
          actions: [
            OutlinedButton.icon(
              onPressed: status?.available == true ? _addRule : null,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加规则'),
            ),
            const SizedBox(width: 8),
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
              : status == null || !status.available
              ? EmptyState(
                  icon: Icons.shield_outlined,
                  title: '防火墙不可用',
                  message: status?.output.isNotEmpty == true
                      ? status!.output
                      : '未检测到受支持的防火墙（Linux: ufw，Windows: Windows Firewall）。',
                  action: OutlinedButton(
                    onPressed: _load,
                    child: const Text('重新检测'),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(
                        MediaQuery.sizeOf(context).width < 720 ? 12 : 24,
                        0,
                        MediaQuery.sizeOf(context).width < 720 ? 12 : 24,
                        12,
                      ),
                      child: Row(
                        children: [
                          StatusPill(
                            text: status.active ? '已启用' : '未启用',
                            good: status.active,
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '规则由系统防火墙直接管理',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: hampanelMuted,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: status.rules.isEmpty
                          ? EmptyState(
                              icon: Icons.rule_outlined,
                              title: '没有规则',
                              message: '点击“添加规则”放行或拒绝端口。',
                            )
                          : ListView.separated(
                              padding: EdgeInsets.fromLTRB(
                                MediaQuery.sizeOf(context).width < 720
                                    ? 10
                                    : 24,
                                0,
                                MediaQuery.sizeOf(context).width < 720
                                    ? 10
                                    : 24,
                                24,
                              ),
                              itemCount: status.rules.length,
                              separatorBuilder: (_, _) =>
                                  const SizedBox(height: 8),
                              itemBuilder: (context, index) {
                                final rule = status.rules[index];
                                final allowed = rule.action
                                    .toUpperCase()
                                    .contains('ALLOW');
                                final compact =
                                    MediaQuery.sizeOf(context).width < 720;
                                final deleteButton = IconButton(
                                  tooltip: '删除',
                                  onPressed: () => _deleteRule(rule),
                                  icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                  ),
                                );
                                return Card(
                                  child: Padding(
                                    padding: EdgeInsets.all(compact ? 12 : 14),
                                    child: compact
                                        ? Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Row(
                                                children: [
                                                  Expanded(
                                                    child: Text(
                                                      rule.to,
                                                      maxLines: 2,
                                                      overflow:
                                                          TextOverflow.ellipsis,
                                                      style: monospace,
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  StatusPill(
                                                    text: rule.action,
                                                    good: allowed,
                                                  ),
                                                  deleteButton,
                                                ],
                                              ),
                                              const SizedBox(height: 4),
                                              Text(
                                                '来源 ${rule.from}',
                                                style: TextStyle(
                                                  fontSize: 11.5,
                                                  color: hampanelMuted,
                                                ),
                                              ),
                                              if (rule.raw
                                                  .trim()
                                                  .isNotEmpty) ...[
                                                const SizedBox(height: 4),
                                                Text(
                                                  rule.raw,
                                                  maxLines: 2,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                  style: TextStyle(
                                                    fontSize: 10.5,
                                                    color: hampanelMuted,
                                                  ),
                                                ),
                                              ],
                                            ],
                                          )
                                        : Row(
                                            children: [
                                              SizedBox(
                                                width: 200,
                                                child: Text(
                                                  rule.to,
                                                  style: monospace,
                                                ),
                                              ),
                                              StatusPill(
                                                text: rule.action,
                                                good: allowed,
                                              ),
                                              const SizedBox(width: 14),
                                              Expanded(
                                                child: Text(
                                                  '来源 ${rule.from}',
                                                  style: TextStyle(
                                                    fontSize: 11.5,
                                                    color: hampanelMuted,
                                                  ),
                                                ),
                                              ),
                                              deleteButton,
                                            ],
                                          ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}
