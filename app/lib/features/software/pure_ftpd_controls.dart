import 'package:material_ui/material_ui.dart';
import '../../core/api_client.dart';

/// Callbacks complete only when the managed operation succeeds.
class PureFtpdControls extends StatefulWidget {
  const PureFtpdControls({super.key, required this.initialized,
    required this.initialize, required this.add, required this.remove});
  final bool initialized;
  final Future<void> Function() initialize;
  final Future<void> Function(String, String) add;
  final Future<void> Function(String) remove;
  @override
  State<PureFtpdControls> createState() => _Controls();
}

class _Controls extends State<PureFtpdControls> {
  final name = TextEditingController(), password = TextEditingController();
  bool busy = false;
  String message = '';
  Future<void> run(Future<void> Function() action) async {
    setState(() { busy = true; message = ''; });
    try {
      await action();
      if (mounted) { password.clear(); message = '操作成功'; }
    } catch (error) {
      message = describeError(error);
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
  @override
  void dispose() { name.dispose(); password.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final valid = RegExp(r'^[a-z][a-z0-9_-]{0,31}$').hasMatch(name.text);
    return Column(children: [
      const Text('显式 FTPS · 控制与数据连接均要求 TLS'),
      if (!widget.initialized) const SelectableText('初始化前将证书链与私钥合并为 /var/lib/hampanel-ftps/server.pem，并设置为 root 所有、权限 0600。默认仅监听本机 2121 端口。'),
      if (!widget.initialized) FilledButton(onPressed: busy ? null : () => run(widget.initialize), child: const Text('初始化并启动'))
      else ...[
        TextField(controller: name, enabled: !busy, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: '虚拟账号')),
        TextField(controller: password, enabled: !busy, obscureText: true, enableSuggestions: false, autocorrect: false, onChanged: (_) => setState(() {}), decoration: const InputDecoration(labelText: '密码')),
        FilledButton(onPressed: busy || !valid || password.text.isEmpty ? null : () => run(() => widget.add(name.text, password.text)), child: const Text('创建账号')),
        TextButton(onPressed: busy || !valid ? null : () => run(() => widget.remove(name.text)), child: const Text('删除账号（保留目录）')),
      ],
      Text(message),
    ]);
  }
}
