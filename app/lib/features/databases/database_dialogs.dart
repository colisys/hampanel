import 'package:material_ui/material_ui.dart';

const engineLabels = {
  'mysql': 'MySQL',
  'redis': 'Redis',
  'mariadb': 'MariaDB',
  'postgres': 'PostgreSQL',
};
const modeLabels = {'host': '主机', 'container': 'Docker / Podman 容器'};
const fieldLabels = {
  'name': '名称',
  'host': '主机地址',
  'port': '端口',
  'user': '管理账号',
  'container': '容器名称或 ID',
  'socket': 'Socket 路径（可选）',
  'password': '密码',
  'confirm': '输入名称以确认',
  'path': '本地文件绝对路径',
};

Future<Map<String, dynamic>?> databaseDialog(
  BuildContext context,
  String title,
  String action,
  List<String> fields, {
  Map initial = const {},
  String? confirm,
  String? message,
  bool instance = false,
  bool editing = false,
}) {
  final form = GlobalKey<FormState>();
  final values = <String, dynamic>{
    if (instance) ...{
      'engine': 'mysql',
      'mode': 'host',
      'host': 'localhost',
      'port': 3306,
      'user': 'root',
    },
    ...initial,
    'password': '',
  };
  return showDialog<Map<String, dynamic>>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) {
        Widget choice(String key, String label, Map<String, String> choices) =>
            DropdownButtonFormField<String>(
              initialValue: values[key] as String,
              decoration: InputDecoration(labelText: label),
              items: [
                for (final e in choices.entries)
                  DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) => update(() {
                if (key == 'engine' && !editing) {
                  values['port'] = switch (v) {
                    'postgres' => 5432,
                    'redis' => 6379,
                    _ => 3306,
                  };
                  values['user'] = switch (v) {
                    'postgres' => 'postgres',
                    'redis' => '',
                    _ => 'root',
                  };
                }
                values[key] = v;
              }),
            );
        Widget input(String key) => TextFormField(
          key: ValueKey(
            '$key:${key == 'port' || key == 'user' ? values['engine'] : ''}',
          ),
          initialValue: '${values[key] ?? ''}',
          obscureText: key == 'password',
          autocorrect: false,
          enableSuggestions: key != 'password',
          decoration: InputDecoration(
            labelText: key == 'password' && editing
                ? '密码（留空保留原密码）'
                : key == 'user' && values['engine'] == 'redis'
                ? 'ACL 用户名（可选）'
                : fieldLabels[key],
          ),
          onChanged: (v) => values[key] = v,
          validator: (raw) {
            final v = raw ?? '';
            if (key == 'confirm' && v != confirm) return '名称不匹配';
            if (key == 'port' &&
                ((int.tryParse(v) ?? 0) < 1 || (int.tryParse(v) ?? 0) > 65535)) {
              return '请输入 1–65535 的端口';
            }
            if (v.trim().isEmpty &&
                key != 'socket' &&
                !(key == 'user' && values['engine'] == 'redis') &&
                !(instance && key == 'password')) {
              return '此项必填';
            }
            return null;
          },
        );
        return AlertDialog(
          title: Text(title),
          scrollable: true,
          content: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (message != null) Text(message),
                if (instance) ...[
                  choice('engine', '数据库引擎', engineLabels),
                  choice('mode', '连接方式', modeLabels),
                ],
                for (final key in fields)
                  if (key != 'container' || values['mode'] == 'container')
                    input(key),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                if (!form.currentState!.validate()) return;
                final result = <String, dynamic>{
                  for (final k in fields) k: values[k] ?? '',
                };
                if (instance) {
                  result.addAll({
                    'engine': values['engine'],
                    'mode': values['mode'],
                    'port': int.parse('${values['port']}'),
                  });
                  if (values['mode'] == 'host') result['container'] = '';
                }
                Navigator.pop(context, result);
              },
              child: Text(action),
            ),
          ],
        );
      },
    ),
  );
}
