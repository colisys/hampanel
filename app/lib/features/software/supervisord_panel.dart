import 'package:material_ui/material_ui.dart';
import '../../core/api_client.dart';

const _path = '/api/v1/supervisord';
typedef SupervisorCall = Future<dynamic> Function(String action, String name, String stream, List<String> argv);

class SupervisordPanel extends StatefulWidget {
  const SupervisordPanel({super.key, required this.call, this.onLaunched});
  factory SupervisordPanel.connected(ApiClient api, {VoidCallback? onLaunched}) => SupervisordPanel(
    onLaunched: onLaunched,
    call: (action, name, stream, argv) => action == 'list' ? api.getJson(_path) :
      api.postJson('$_path/action', {'action': action, 'name': name, 'stream': stream, 'argv': argv}),
  );
  final SupervisorCall call;
  final VoidCallback? onLaunched;
  @override
  State<SupervisordPanel> createState() => _Panel();
}

class _Panel extends State<SupervisordPanel> {
  List<dynamic> rows = [];
  String message = '';
  bool busy = false;
  @override
  void initState() { super.initState(); run('list'); }

  Future<void> run(String action, [String name = '', String stream = 'stdout', List<String> argv = const []]) async {
    if (busy) return;
    setState(() { busy = true; message = ''; });
    try {
      if (action == 'logs') {
        final text = await widget.call(action, name, stream, argv);
        if (!mounted) return;
        await showDialog<void>(context: context, builder: (ctx) => AlertDialog(
          title: Text('$name · $stream'), content: SingleChildScrollView(child: SelectableText('$text')),
          actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
        ));
      } else {
        if (action != 'list') await widget.call(action, name, stream, argv);
        if (!mounted) return;
        if (action == 'launch') widget.onLaunched?.call();
        rows = await widget.call('list', '', 'stdout', const []) as List<dynamic>;
      }
    } catch (e) { message = e.toString(); } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> edit(String action, [String name = '']) async {
    var program = name;
    var tokens = '';
    final confirmed = await showDialog<bool>(context: context, builder: (ctx) => AlertDialog(
      title: Text({'create': '创建程序', 'update': '更新 $name', 'delete': '删除 $name？'}[action]!),
      content: action == 'delete' ? const Text('将停止程序并删除受管配置。') : SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (action == 'create') TextField(decoration: const InputDecoration(labelText: '程序名称'), onChanged: (v) => program = v),
        TextField(maxLines: 4, decoration: const InputDecoration(labelText: 'argv（每行一个元素）', hintText: '/bin/sleep\n60'), onChanged: (v) => tokens = v),
        const Text('仅支持 /bin/sleep 正整数秒数，或 /bin/echo 加受限词元。'),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确认'))],
    ));
    if (mounted && confirmed == true) await run(action, program, 'stdout', action == 'delete' ? [] : tokens.split('\n'));
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    Wrap(children: [
      TextButton(onPressed: busy ? null : () => edit('create'), child: const Text('创建程序')),
      TextButton(onPressed: busy ? null : () => run('launch'), child: const Text('启动面板 Supervisord')),
      TextButton(onPressed: busy ? null : () => run('list'), child: const Text('刷新进程')),
    ]),
    if (busy) const LinearProgressIndicator(),
    if (message.isNotEmpty) SelectableText(message),
    for (final p in rows) ListTile(title: Text(p['name'] as String), subtitle: Text('${p['state']} · PID ${p['pid']}'),
      trailing: PopupMenuButton<String>(enabled: !busy, onSelected: (a) {
        if (a == 'update' || a == 'delete') { edit(a, (p['name'] as String).split(':').first); return; }
        final log = a == 'stdout' || a == 'stderr';
        run(log ? 'logs' : a, p['name'] as String, log ? a : 'stdout');
      }, itemBuilder: (_) => [for (final a in ['start','stop','restart','stdout','stderr', if (p['managed'] == true) ...['update', 'delete']]) PopupMenuItem(value: a, child: Text(a))]),
    ),
  ]);
}
