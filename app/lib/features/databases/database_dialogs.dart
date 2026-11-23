import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../ui/remote_picker.dart';

const engineLabels = {
  'mysql': 'MySQL',
  'redis': 'Redis',
  'mariadb': 'MariaDB',
  'postgres': 'PostgreSQL',
  'mongo': 'MongoDB',
  'sqlite': 'SQLite',
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
  'path': '受管主机上的 SQLite 文件绝对路径',
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
  ApiClient? api,
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
        final sqlite = instance && values['engine'] == 'sqlite';
        Widget choice(String key, String label, Map<String, String> choices) =>
            DropdownButtonFormField<String>(
              isExpanded: true,
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
                    'mongo' => 27017,
                    _ => 3306,
                  };
                  values['user'] = switch (v) {
                    'postgres' => 'postgres',
                    'redis' => '',
                    'mongo' => 'admin',
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
                ((int.tryParse(v) ?? 0) < 1 ||
                    (int.tryParse(v) ?? 0) > 65535)) {
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
              spacing: 14,
              children: [
                if (message != null) Text(message),
                if (instance) ...[
                  choice('engine', '数据库引擎', engineLabels),
                  if (!sqlite) choice('mode', '连接方式', modeLabels),
                ],
                for (final key in sqlite ? ['name', 'path'] : fields)
                  if (key != 'container' || values['mode'] == 'container')
                    // A socket lives on the daemon host, so it is picked rather
                    // than typed; everything else here is ordinary text.
                    if ((key == 'socket' || key == 'path') && api != null)
                      _HostPathField(
                        key: ValueKey(key),
                        field: key,
                        api: api,
                        initial: '${values[key] ?? ''}',
                        onChanged: (v) => values[key] = v,
                      )
                    else
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
                if (sqlite) {
                  if ('${values['path'] ?? ''}'.trim().isEmpty) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('请选择已有 SQLite 文件')),
                    );
                    return;
                  }
                  Navigator.pop(context, {
                    'name': values['name'],
                    'engine': 'sqlite',
                    'mode': 'host',
                    'path': values['path'],
                  });
                  return;
                }
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

/// The unix socket is a host path, so it gets the remote picker. Kept as its
/// own widget because RemotePathField needs a persistent controller while this
/// dialog is a stateless builder.
class _HostPathField extends StatefulWidget {
  const _HostPathField({
    super.key,
    required this.field,
    required this.api,
    required this.initial,
    required this.onChanged,
  });

  final String field;
  final ApiClient api;
  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<_HostPathField> createState() => _HostPathFieldState();
}

class _HostPathFieldState extends State<_HostPathField> {
  late final _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: RemotePathField(
      api: widget.api,
      controller: _controller,
      label: fieldLabels[widget.field]!,
      allowFiles: true,
      hintText: widget.field == 'path'
          ? '/srv/data/app.db'
          : '/var/run/mysqld/mysqld.sock',
      onChanged: widget.onChanged,
      onPicked: widget.onChanged,
    ),
  );
}
