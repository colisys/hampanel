import 'package:material_ui/material_ui.dart';
import '../../core/api_client.dart';
import '../../ui/remote_picker.dart';

class ClamavPanel extends StatefulWidget {
  const ClamavPanel({super.key, required this.client, this.onInitialized});
  final ApiClient client;
  final VoidCallback? onInitialized;
  @override
  State<ClamavPanel> createState() => _ClamavPanelState();
}

class _ClamavPanelState extends State<ClamavPanel> {
  // Both paths are on the daemon host, so they are picked with the remote
  // browser instead of being typed from memory.
  final _database = TextEditingController(text: '/var/lib/clamav');
  final _scanPath = TextEditingController();
  final _threads = TextEditingController(text: '2');
  String path = '', message = '';
  bool busy = false;

  @override
  void dispose() {
    _database.dispose();
    _scanPath.dispose();
    _threads.dispose();
    super.dispose();
  }

  Future<void> run(String action) async {
    setState(() {
      busy = true;
      message = '';
    });
    try {
      const base = '/api/v1/clamav';
      final result = action == 'status'
          ? await widget.client.getJson(base)
          : await widget.client.postJson(
              '$base/$action',
              action == 'scan'
                  ? {'path': path}
                  : {
                      'database': _database.text,
                      'threads': int.tryParse(_threads.text) ?? 2,
                    },
              timeout: const Duration(minutes: 6),
            );
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
  Widget build(BuildContext context) => Column(
    children: [
      RemotePathField(
        api: widget.client,
        controller: _database,
        label: '病毒库绝对路径',
        initialPath: '/var/lib',
      ),
      TextFormField(
        controller: _threads,
        decoration: const InputDecoration(labelText: '扫描线程（1–16）'),
      ),
      RemotePathField(
        api: widget.client,
        controller: _scanPath,
        label: '服务器文件或目录绝对路径',
        allowFiles: true,
        hintText: '/home/user 或 /var/www',
        onPicked: (value) => setState(() => path = value),
        onChanged: (value) => setState(() => path = value),
      ),
      Wrap(
        children: [
          TextButton(onPressed: busy ? null : () => run('status'), child: const Text('刷新状态')),
          TextButton(
            onPressed: busy ? null : () => run('initialize'),
            child: const Text('初始化并启动'),
          ),
          TextButton(
            onPressed: busy || !path.startsWith('/')
                ? null
                : () => run('scan'),
            child: const Text('扫描'),
          ),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      SelectableText(message),
    ],
  );
}
