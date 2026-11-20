import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';

const _path = '/api/v1/notifications';
const _sections = {
  'Bark': {
    'bark_enabled': '启用 Bark',
    'bark_server': '服务器地址',
    'bark_key': '设备密钥',
    'bark_group': '分组',
    'bark_sound': '提示音',
    'bark_level': '通知级别',
  },
  'ntfy': {
    'ntfy_enabled': '启用 ntfy',
    'ntfy_server': '服务器地址',
    'ntfy_topic': '主题',
    'ntfy_token': '访问令牌（可选）',
    'ntfy_priority': '优先级',
    'ntfy_tags': '标签（逗号分隔）',
  },
  '通知事件': {
    'event_login': '登录',
    'event_ai_command': 'AI 命令',
    'event_service_restart': '服务重启',
    'event_docker_restart': '容器重启',
    'event_availability': '可用性',
  },
  '资源告警': {
    'memory_percent': '内存阈值（%）',
    'disk_percent': '磁盘阈值（%）',
    'cooldown_minutes': '冷却时间（分钟）',
  },
};

class NotificationSettings extends StatefulWidget {
  const NotificationSettings({super.key, required this.api});
  final ApiClient api;

  @override
  State<NotificationSettings> createState() => _NotificationSettingsState();
}

class _NotificationSettingsState extends State<NotificationSettings> {
  final _form = GlobalKey<FormState>();
  Map<String, dynamic>? _draft;
  bool _busy = false;
  bool _dirty = false;
  String _message = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final config = await widget.api.getJson(_path) as Map<String, dynamic>;
      if (mounted) {
        setState(() {
          _draft = Map.of(config);
          _message = '';
        });
      }
    } catch (_) {
      if (mounted) setState(() => _message = '无法读取通知设置，请检查服务端连接。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit([String? provider]) async {
    if (provider == null && !_form.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      if (provider == null) {
        await widget.api.putJson(_path, Map.of(_draft!));
        if (!mounted) return;
        _dirty = false;
        _message = '通知设置已保存';
      } else {
        final result = await widget.api.postJson('$_path/test', {
          'provider': provider,
        });
        if (!mounted) return;
        _message = result['ok'] == true ? '测试通知已发送' : '发送失败，请检查推送服务配置。';
      }
    } catch (_) {
      if (mounted) _message = provider == null ? '保存失败，请检查配置和连接。' : '测试请求失败。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _change(String key, dynamic value) => setState(() {
    _draft![key] = value;
    _dirty = true;
    _message = '';
  });

  Widget _field(String key, String label) {
    final value = _draft![key];
    if (value is bool) {
      return SwitchListTile(
        title: Text(label),
        value: value,
        onChanged: _busy ? null : (v) => _change(key, v),
      );
    }
    final numeric = key.endsWith('_percent') || key == 'cooldown_minutes';
    final provider = key.split('_').first;
    return TextFormField(
      key: ValueKey(key),
      initialValue: value?.toString() ?? '',
      enabled: !_busy,
      decoration: InputDecoration(labelText: label),
      obscureText: key == 'bark_key' || key == 'ntfy_token',
      autocorrect: false,
      enableSuggestions: false,
      keyboardType: numeric ? TextInputType.number : TextInputType.text,
      onChanged: (v) => _change(key, numeric ? int.tryParse(v) : v),
      validator: (input) {
        final v = input ?? '';
        if (numeric) {
          final max = key == 'cooldown_minutes' ? 1440 : 100;
          final n = int.tryParse(v);
          if (n == null || n < 1 || n > max) return '请输入 1 到 $max 的整数';
        }
        if (_draft!['${provider}_enabled'] != true) return null;
        if (key.endsWith('_server')) {
          final uri = Uri.tryParse(v);
          if (uri == null ||
              !{'http', 'https'}.contains(uri.scheme) ||
              uri.host.isEmpty) {
            return '请输入 HTTP 或 HTTPS 地址';
          }
        }
        if (key == 'bark_key' || key == 'ntfy_topic') {
          final max = key == 'bark_key' ? 128 : 64;
          if (v.isEmpty || v.length > max || RegExp('[^A-Za-z0-9_-]').hasMatch(v)) {
            return '请输入 1 到 $max 位字母、数字、下划线或短横线';
          }
        }
        return null;
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_draft == null) {
      return _busy ? const CircularProgressIndicator() : Column(children: [
        Text(_message),
        TextButton(onPressed: _load, child: const Text('重试')),
      ]);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: Form(key: _form, child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          const Text('推送配置保存在当前服务端。请先保存更改，再发送测试通知。'),
          for (final section in _sections.entries) ...[
            Text(section.key, style: Theme.of(context).textTheme.titleMedium),
            for (final field in section.value.entries) _field(field.key, field.value),
          ],
          Wrap(spacing: 8, children: [
            FilledButton(onPressed: _busy || !_dirty ? null : () => _submit(), child: const Text('保存通知设置')),
            for (final name in ['Bark', 'ntfy'])
              OutlinedButton(
                onPressed: _busy || _dirty || _draft!['${name.toLowerCase()}_enabled'] != true
                    ? null : () => _submit(name.toLowerCase()),
                child: Text('测试 $name'),
              ),
          ]),
          if (_busy) const LinearProgressIndicator(),
          if (_message.isNotEmpty) Text(_message),
        ],
      )),
    );
  }
}
