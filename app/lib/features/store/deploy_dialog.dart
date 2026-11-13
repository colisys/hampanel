import 'package:material_ui/material_ui.dart';

import '../../core/models/store_app.dart';
import '../../ui/theme.dart';

Future<Map<String, String>?> showDeployDialog(
  BuildContext context,
  StoreApp app,
) async {
  final controllers = <String, TextEditingController>{
    for (final param in app.params)
      param.key: TextEditingController(text: param.defaultValue),
  };

  final submitted = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('部署 ${app.name}'),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '容器通过 Docker Compose 启动。端口冲突或镜像拉取失败会在结果中显示。',
              style: TextStyle(
                fontSize: 11.5,
                color: hampanelMuted,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            for (final param in app.params) ...[
              TextField(
                controller: controllers[param.key],
                keyboardType: param.isPort
                    ? TextInputType.number
                    : param.isPassword
                    ? TextInputType.visiblePassword
                    : TextInputType.text,
                decoration: InputDecoration(
                  labelText: param.label,
                  hintText: param.isPassword ? '留空自动生成随机密码' : null,
                  helperText: param.isPassword ? '部署完成后会显示实际使用的密码' : null,
                ),
              ),
              const SizedBox(height: 12),
            ],
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
          child: const Text('部署'),
        ),
      ],
    ),
  );

  if (submitted != true) {
    for (final controller in controllers.values) {
      controller.dispose();
    }
    return null;
  }

  final values = <String, String>{
    for (final entry in controllers.entries) entry.key: entry.value.text.trim(),
  };
  for (final controller in controllers.values) {
    controller.dispose();
  }
  return values;
}

Future<void> showDeployedDialog(
  BuildContext context,
  String appName,
  List<dynamic> params,
  String output,
) async {
  final rows = <Widget>[];
  for (final item in params.whereType<Map<String, dynamic>>()) {
    final key = item['key'] as String? ?? '';
    final value = item['value'] as String? ?? '';
    final secret = item['secret'] as bool? ?? false;
    rows.add(
      Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                key,
                style: const TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: monospace.copyWith(
                  fontSize: 12,
                  color: secret ? hampanelAccent : const Color(0xFFD7E2EA),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('$appName 部署结果'),
      content: SizedBox(
        width: 760,
        height: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (rows.isNotEmpty) ...[
                const Text(
                  '参数',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                ...rows,
                const SizedBox(height: 8),
              ],
              const Text(
                '输出',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 8),
              SelectableText(output, style: monospace),
            ],
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
}

Future<void> showOutputDialog(
  BuildContext context,
  String title,
  String output,
) async {
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: SizedBox(
        width: 820,
        height: 500,
        child: SingleChildScrollView(
          child: SelectableText(
            output.isEmpty ? '（无输出）' : output,
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
}
