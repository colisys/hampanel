import 'package:material_ui/material_ui.dart';
import '../../core/api_client.dart';

class ClamavPanel extends StatefulWidget {
  const ClamavPanel({super.key, required this.client, this.onInitialized});
  final ApiClient client;
  final VoidCallback? onInitialized;
  @override
  State<ClamavPanel> createState() => _ClamavPanelState();
}

class _ClamavPanelState extends State<ClamavPanel> {
  String database = '/var/lib/clamav', threads = '2', path = '', message = '';
  bool busy = false;

  Future<void> run(String action) async {
    setState(() { busy = true; message = ''; });
    try {
      const base = '/api/v1/clamav';
      final result = action == 'status' ? await widget.client.getJson(base)
          : await widget.client.postJson('$base/$action', action == 'scan'
              ? {'path': path} : {'database': database, 'threads': int.parse(threads)},
              timeout: const Duration(minutes: 6));
      if (!mounted) return;
      if (action == 'initialize') widget.onInitialized?.call();
      message = switch (action) {
        'status' => '配置：${result['initialized']}  运行：${result['active']}',
        'scan' => '${result['verdict']} (${result['exit_code']})\n${result['output']}',
        _ => '${result['output']}',
      };
    } catch (error) {
      if (mounted) message = error.toString();
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(children: [
    TextFormField(initialValue: database, decoration: const InputDecoration(labelText: '病毒库绝对路径'), onChanged: (v) => database = v),
    TextFormField(initialValue: threads, decoration: const InputDecoration(labelText: '扫描线程（1–16）'), onChanged: (v) => threads = v),
    TextField(decoration: const InputDecoration(labelText: '服务器文件或目录绝对路径'), onChanged: (v) => setState(() => path = v)),
    Wrap(children: [
      TextButton(onPressed: busy ? null : () => run('status'), child: const Text('刷新状态')),
      TextButton(onPressed: busy ? null : () => run('initialize'), child: const Text('初始化并启动')),
      TextButton(onPressed: busy || !path.startsWith('/') ? null : () => run('scan'), child: const Text('扫描')),
    ]),
    if (busy) const LinearProgressIndicator(),
    SelectableText(message),
  ]);
}
