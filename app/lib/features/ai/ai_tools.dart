import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/ai_config.dart';
import '../../core/api_client.dart';
import '../../ui/log_review_page.dart';

class AiTool {
  const AiTool({
    required this.name,
    required this.description,
    required this.parameters,
    required this.mutating,
    required this.summary,
    required this.run,
    this.defaultEnabled = true,
    this.highRisk = false,
    this.requiresApproval,
    this.review,
  });

  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final bool mutating;
  final bool defaultEnabled;

  /// High-risk tools are hidden from the default set and listed separately in
  /// settings. Log reads live here because log lines may contain secrets.
  final bool highRisk;

  /// Dynamic approval predicate, e.g. sensitive file reads.
  final bool Function(Map<String, dynamic> args)? requiresApproval;

  /// When set, the call is not executed directly: the client fetches the
  /// content, opens the review editor and returns the edited text (or null when
  /// the user cancels). Used for log reads, which may contain secrets.
  final Future<String?> Function(
    BuildContext context,
    ApiClient api,
    Map<String, dynamic> args,
  )?
  review;
  final String Function(Map<String, dynamic> args) summary;
  final Future<String> Function(ApiClient api, Map<String, dynamic> args) run;
}

List<AiTool> buildAiTools() {
  return [
    AiTool(
      name: 'submit_task',
      description:
          '提交异步任务并立即返回任务 ID。长操作（构建、安装、部署、重载）都走这里，不要等待完成。',
      parameters: _object(
        {
          'kind': {
            'type': 'string',
            'description':
                '任务种类，如 nix.build、package.install、store.deploy、sites.reload',
          },
          'title': _string('可读标题'),
          'params': {
            'type': 'object',
            'description': '任务参数，随 kind 而定',
          },
        },
        ['kind'],
      ),
      mutating: true,
      summary: (args) => '提交任务 ${args['kind']}',
      run: (api, args) async => _result(
        await api.postJson('/api/v1/tasks', {
          'kind': args['kind'],
          'title': args['title'] ?? args['kind'],
          'params': args['params'] ?? const <String, dynamic>{},
        }),
      ),
    ),
    AiTool(
      name: 'get_task',
      description: '读取任务状态与最新输出片段。',
      parameters: _object({'id': _string('任务 ID')}, ['id']),
      mutating: false,
      summary: (args) => '读取任务 ${args['id']}',
      run: (api, args) async =>
          _result(await api.getJson('/api/v1/tasks/${_segment(args, 'id')}')),
    ),
    AiTool(
      name: 'cancel_task',
      description: '取消仍在运行的任务。',
      parameters: _object({'id': _string('任务 ID')}, ['id']),
      mutating: true,
      summary: (args) => '取消任务 ${args['id']}',
      run: (api, args) async => _result(
        await api.postJson(
          '/api/v1/tasks/${_segment(args, 'id')}/cancel',
          const {},
        ),
      ),
    ),
    AiTool(
      name: 'get_system_info',
      description: '读取主机名、系统版本、内核、CPU 与运行时长。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取主机信息',
      run: (api, _) async => _result(await api.getJson('/api/v1/system')),
    ),
    AiTool(
      name: 'get_metrics',
      description: '读取 CPU、内存、磁盘与网络指标。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取实时指标',
      run: (api, _) async => _result(await api.getJson('/api/v1/metrics')),
    ),
    AiTool(
      name: 'list_log_sources',
      description:
          '列出可读取的日志源（Web 服务、认证、系统、站点）。读取日志前先调用它拿到 source。',
      parameters: _object({}),
      mutating: false,
      defaultEnabled: false,
      highRisk: true,
      summary: (_) => '列出日志源',
      run: (api, _) async =>
          _result(await api.getJson('/api/v1/logs/sources')),
    ),
    AiTool(
      name: 'read_logs',
      description:
          '读取指定日志源的尾部内容。source 来自 list_log_sources；audit 是面板审计日志。',
      parameters: _object({
        'source': _string('日志源 id，例如 audit、journal:auth、site-xxx'),
        'lines': {
          'type': 'integer',
          'description': '读取行数，1-500，默认 100',
        },
      }, ['source']),
      mutating: false,
      defaultEnabled: false,
      highRisk: true,
      review: (context, api, args) {
        final source = _segment(args, 'source');
        final lines = _clampLines(args, 100);
        return _reviewLog(
          context,
          api,
          title: '${args['source']} · 最近 $lines 行',
          path: '/api/v1/logs/tail',
          query: {'source': source, 'lines': '$lines'},
          contentKey: 'content',
        );
      },
      summary: (args) => '读取日志 ${args['source']}',
      run: (api, args) async {
        final source = _segment(args, 'source');
        final lines = _clampLines(args, 100);
        return _result(
          await api.getJson(
            '/api/v1/logs/tail',
            query: {'source': source, 'lines': '$lines'},
          ),
        );
      },
    ),
    AiTool(
      name: 'read_service_logs',
      description: '读取 systemd 单元的 journal 日志。',
      parameters: _object({
        'unit': _string('单元名，例如 nginx.service'),
        'lines': {
          'type': 'integer',
          'description': '读取行数，1-500，默认 100',
        },
      }, ['unit']),
      mutating: false,
      defaultEnabled: false,
      highRisk: true,
      review: (context, api, args) {
        final unit = _segment(args, 'unit');
        final lines = _clampLines(args, 100);
        return _reviewLog(
          context,
          api,
          title: '${args['unit']} · 最近 $lines 行',
          path: '/api/v1/services/$unit/logs',
          query: {'lines': '$lines'},
          contentKey: 'lines',
        );
      },
      summary: (args) => '读取 ${args['unit']} 日志',
      run: (api, args) async {
        final unit = _segment(args, 'unit');
        final lines = _clampLines(args, 100);
        return _result(
          await api.getJson(
            '/api/v1/services/$unit/logs',
            query: {'lines': '$lines'},
          ),
        );
      },
    ),
    AiTool(
      name: 'read_container_logs',
      description: '读取 Docker/Podman 容器的日志尾部。',
      parameters: _object({
        'id': _string('容器 ID'),
        'lines': {
          'type': 'integer',
          'description': '读取行数，1-500，默认 100',
        },
      }, ['id']),
      mutating: false,
      defaultEnabled: false,
      highRisk: true,
      review: (context, api, args) {
        final id = _segment(args, 'id');
        final lines = _clampLines(args, 100);
        return _reviewLog(
          context,
          api,
          title: '容器 ${args['id']} · 最近 $lines 行',
          path: '/api/v1/docker/containers/$id/logs',
          query: {'lines': '$lines'},
          contentKey: 'output',
        );
      },
      summary: (args) => '读取容器 ${args['id']} 日志',
      run: (api, args) async {
        final id = _segment(args, 'id');
        final lines = _clampLines(args, 100);
        return _result(
          await api.getJson(
            '/api/v1/docker/containers/$id/logs',
            query: {'lines': '$lines'},
          ),
        );
      },
    ),
    AiTool(
      name: 'list_processes',
      description: '列出进程（按内存排序），可指定数量上限。',
      parameters: _object({
        'limit': {'type': 'integer', 'description': '1-500，默认 100'},
      }),
      mutating: false,
      summary: (_) => '读取进程列表',
      run: (api, args) async {
        final limit = ((args['limit'] as num?)?.toInt() ?? 100).clamp(1, 500);
        return _result(
          await api.getJson('/api/v1/processes', query: {'limit': '$limit'}),
        );
      },
    ),
    AiTool(
      name: 'list_files',
      description: '列出服务器上某个绝对路径下的文件与目录。',
      parameters: _object({'path': _string('绝对路径')}, ['path']),
      mutating: false,
      summary: (args) => '列出 ${args['path']}',
      run: (api, args) async => _result(
        await api.getJson(
          '/api/v1/files',
          query: {'path': _requireString(args, 'path')},
        ),
      ),
    ),
    AiTool(
      name: 'read_file',
      description: '读取文本文件内容（最多 2MB）。',
      parameters: _object({'path': _string('绝对路径')}, ['path']),
      mutating: false,
      summary: (args) => '读取 ${args['path']}',
      run: (api, args) async => _result(
        await api.getJson(
          '/api/v1/files/content',
          query: {'path': _requireString(args, 'path')},
        ),
      ),
    ),
    AiTool(
      name: 'list_recycle_bin',
      description: '列出回收站内容。通过面板删除的内容都在这里。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取回收站',
      run: (api, _) async => _result(await api.getJson('/api/v1/recycle')),
    ),
    AiTool(
      name: 'list_services',
      description: '列出 systemd 服务。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '列出服务',
      run: (api, _) async => _result(await api.getJson('/api/v1/services')),
    ),
    AiTool(
      name: 'list_containers',
      description: '列出 Docker 容器。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '列出容器',
      run: (api, _) async =>
          _result(await api.getJson('/api/v1/docker/containers')),
    ),
    AiTool(
      name: 'list_sites',
      description: '列出 Nginx 站点。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '列出站点',
      run: (api, _) async => _result(await api.getJson('/api/v1/sites')),
    ),
    AiTool(
      name: 'list_firewall',
      description: '读取防火墙状态与规则。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取防火墙',
      run: (api, _) async => _result(await api.getJson('/api/v1/firewall')),
    ),
    AiTool(
      name: 'list_cron',
      description: '读取计划任务。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取计划任务',
      run: (api, _) async => _result(await api.getJson('/api/v1/cron')),
    ),
    AiTool(
      name: 'ssh_status',
      description: '读取 SSH 服务与生效配置。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取 SSH 状态',
      run: (api, _) async => _result(await api.getJson('/api/v1/ssh')),
    ),
    AiTool(
      name: 'fail2ban_status',
      description: '读取 Fail2ban jail、封禁 IP 与阈值。',
      parameters: _object({}),
      mutating: false,
      summary: (_) => '读取 Fail2ban 状态',
      run: (api, _) async => _result(await api.getJson('/api/v1/fail2ban')),
    ),
    AiTool(
      name: 'write_file',
      description: '写入文本文件。会覆盖原文件，但保存前会自动创建历史版本；不能执行任意 shell。',
      parameters: _object(
        {'path': _string('绝对路径'), 'content': _string('新的文件内容')},
        ['path', 'content'],
      ),
      mutating: true,
      summary: (args) => '写入文件 ${args['path']}（自动创建历史版本）',
      run: (api, args) async => _result(
        await api.putJson('/api/v1/files/content', {
          'path': _requireString(args, 'path'),
          'content': _requireString(args, 'content', allowEmpty: true),
        }),
      ),
    ),
    AiTool(
      name: 'delete_path',
      description: '删除文件或目录。只能移动到回收站，可恢复；不会永久删除。',
      parameters: _object({'path': _string('绝对路径')}, ['path']),
      mutating: true,
      summary: (args) => '删除 ${args['path']}（移动到回收站）',
      run: (api, args) async => _result(
        await api.postJson('/api/v1/files/delete', {
          'paths': [_requireString(args, 'path')],
        }),
      ),
    ),
    AiTool(
      name: 'restore_recycle_item',
      description: '从回收站恢复指定项目。',
      parameters: _object({'id': _string('回收站项目 id')}, ['id']),
      mutating: true,
      summary: (args) => '从回收站恢复 ${args['id']}',
      run: (api, args) async => _result(
        await api.postJson('/api/v1/recycle/restore', {
          'id': _requireString(args, 'id'),
        }),
      ),
    ),
    AiTool(
      name: 'service_action',
      description: '对 systemd 服务执行 start/stop/restart/reload/enable/disable。',
      parameters: _object(
        {
          'unit': _string('服务名，例如 nginx'),
          'action': {
            'type': 'string',
            'enum': ['start', 'stop', 'restart', 'reload', 'enable', 'disable'],
          },
        },
        ['unit', 'action'],
      ),
      mutating: true,
      summary: (args) => '对服务 ${args['unit']} 执行 ${args['action']}',
      run: (api, args) async {
        final unit = _segment(args, 'unit');
        final action = _enum(args, 'action', const [
          'start',
          'stop',
          'restart',
          'reload',
          'enable',
          'disable',
        ]);
        return _result(
          await api.postJson('/api/v1/services/$unit/$action', const {}),
        );
      },
    ),
    AiTool(
      name: 'container_action',
      description: '对 Docker 容器执行 start/stop/restart/rm。',
      parameters: _object(
        {
          'id': _string('容器 id 或名称'),
          'action': {
            'type': 'string',
            'enum': ['start', 'stop', 'restart', 'rm'],
          },
        },
        ['id', 'action'],
      ),
      mutating: true,
      summary: (args) => '对容器 ${args['id']} 执行 ${args['action']}',
      run: (api, args) async {
        final id = _segment(args, 'id');
        final action = _enum(args, 'action', const [
          'start',
          'stop',
          'restart',
          'rm',
        ]);
        return _result(
          await api.postJson('/api/v1/docker/containers/$id/$action', const {}),
        );
      },
    ),
    AiTool(
      name: 'add_firewall_rule',
      description: '添加防火墙规则（allow/deny/limit）。',
      parameters: _object(
        {
          'action': {
            'type': 'string',
            'enum': ['allow', 'deny', 'limit'],
          },
          'port': _string('端口或 port/proto，例如 443/tcp'),
          'from': _string('可选来源 IP/CIDR'),
          'comment': _string('可选备注'),
        },
        ['action', 'port'],
      ),
      mutating: true,
      summary: (args) => '${args['action']} 端口 ${args['port']}',
      run: (api, args) async {
        final action = _enum(args, 'action', const ['allow', 'deny', 'limit']);
        return _result(
          await api.postJson('/api/v1/firewall/rules', {
            'action': action,
            'port': _requireString(args, 'port'),
            if (args['from'] is String) 'from': args['from'],
            if (args['comment'] is String) 'comment': args['comment'],
          }),
        );
      },
    ),
    AiTool(
      name: 'add_cron_job',
      description:
          '创建 root 计划任务。该工具默认关闭，需要在系统设置中显式勾选；'
          '会执行计划命令，每次创建都必须人工批准。',
      parameters: _object(
        {'schedule': _string('5 段 cron 表达式'), 'command': _string('计划执行的命令')},
        ['schedule', 'command'],
      ),
      mutating: true,
      defaultEnabled: false,
      summary: (args) => '添加计划任务 ${args['schedule']} → ${args['command']}',
      run: (api, args) async => _result(
        await api.postJson('/api/v1/cron', {
          'schedule': _requireString(args, 'schedule'),
          'command': _requireString(args, 'command'),
        }),
      ),
    ),
    AiTool(
      name: 'reload_sites',
      description: '校验并重载 Nginx 配置。',
      parameters: _object({}),
      mutating: true,
      summary: (_) => '重载 Nginx',
      run: (api, _) async => _result(
        await api.postJson('/api/v1/tasks', {
          'kind': 'sites.reload',
          'title': '重载 WebServer',
          'params': const <String, dynamic>{},
        }),
      ),
    ),
    AiTool(
      name: 'fail2ban_ban',
      description: '在指定 jail 中封禁 IP。',
      parameters: _object(
        {'jail': _string('jail 名称'), 'ip': _string('IPv4 或 IPv6')},
        ['jail', 'ip'],
      ),
      mutating: true,
      summary: (args) => '在 ${args['jail']} 封禁 ${args['ip']}',
      run: (api, args) async => _result(
        await api.postJson('/api/v1/fail2ban/ban', {
          'jail': _requireString(args, 'jail'),
          'ip': _requireString(args, 'ip'),
        }),
      ),
    ),
    AiTool(
      name: 'fail2ban_unban',
      description: '在指定 jail 中解封 IP。',
      parameters: _object(
        {'jail': _string('jail 名称'), 'ip': _string('IPv4 或 IPv6')},
        ['jail', 'ip'],
      ),
      mutating: true,
      summary: (args) => '在 ${args['jail']} 解封 ${args['ip']}',
      run: (api, args) async => _result(
        await api.postJson('/api/v1/fail2ban/unban', {
          'jail': _requireString(args, 'jail'),
          'ip': _requireString(args, 'ip'),
        }),
      ),
    ),
  ];
}

Map<String, dynamic> _object(
  Map<String, dynamic> properties, [
  List<String> required = const [],
]) {
  return {
    'type': 'object',
    'properties': properties,
    'required': required,
    'additionalProperties': false,
  };
}

Map<String, dynamic> _string(String description) => {
  'type': 'string',
  'description': description,
};

String _requireString(
  Map<String, dynamic> args,
  String key, {
  bool allowEmpty = false,
}) {
  final value = args[key];
  if (value is! String || (!allowEmpty && value.trim().isEmpty)) {
    throw ArgumentError('参数 $key 缺失');
  }
  return value;
}

String _segment(Map<String, dynamic> args, String key) {
  final value = _requireString(args, key);
  if (!RegExp(r'^[A-Za-z0-9@._:-]+$').hasMatch(value)) {
    throw ArgumentError('参数 $key 含有非法字符');
  }
  return value;
}

Future<String?> _reviewLog(
  BuildContext context,
  ApiClient api, {
  required String title,
  required String path,
  required Map<String, String> query,
  required String contentKey,
}) async {
  final json = await api.getJson(path, query: query);
  final map = json as Map<String, dynamic>? ?? const {};
  final raw = map[contentKey];
  final content = raw is List
      ? raw.whereType<String>().join('\n')
      : raw is String
      ? raw
      : const JsonEncoder.withIndent('  ').convert(json);
  if (!context.mounted) return null;
  return Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (_) => LogReviewPage(title: title, content: content),
    ),
  );
}

int _clampLines(Map<String, dynamic> args, int fallback) {
  final value = args['lines'];
  final parsed = value is num ? value.toInt() : fallback;
  return parsed.clamp(1, 500);
}

String _enum(Map<String, dynamic> args, String key, List<String> allowed) {
  final value = _requireString(args, key);
  if (!allowed.contains(value)) {
    throw ArgumentError('参数 $key 必须是 ${allowed.join(', ')}');
  }
  return value;
}

String _result(dynamic value) {
  final encoded = jsonEncode(value);
  if (encoded.length <= 8000) return encoded;
  return '${encoded.substring(0, 8000)}…(truncated)';
}

/// In-memory view of the user's AI tool selection. Loaded from AiConfig and
/// updated by the Settings page; the AI page reads it at send time.
class AiToolPreferences {
  static final ValueNotifier<Set<String>> enabled = ValueNotifier(<String>{});
  static final ValueNotifier<List<String>> sensitivePaths = ValueNotifier(
    <String>[..._defaultSensitivePaths],
  );

  static const _defaultSensitivePaths = <String>[
    '/etc/shadow',
    '/etc/gshadow',
    '/etc/sudoers',
    '/etc/sudoers.d',
    '/etc/ssh',
    '/root/.ssh',
    '/etc/ssl/private',
    '/var/lib/hampanel/tls',
  ];

  static List<String> get defaultsForSensitivePaths =>
      List<String>.from(_defaultSensitivePaths);

  static bool isSensitivePath(String rawPath) {
    final path = _normalizePath(rawPath);
    if (path.isEmpty) return true;
    for (final rawPrefix in sensitivePaths.value) {
      final prefix = _normalizePath(rawPrefix);
      if (prefix.isEmpty) continue;
      if (path == prefix ||
          path.startsWith('$prefix/') ||
          path.startsWith('$prefix\\')) {
        return true;
      }
    }
    return false;
  }

  static String _normalizePath(String value) {
    var path = value.trim();
    while (path.length > 1 && (path.endsWith('/') || path.endsWith('\\'))) {
      path = path.substring(0, path.length - 1);
    }
    return path;
  }

  static Set<String> defaultsFor(List<AiTool> tools) => {
    for (final tool in tools)
      if (tool.defaultEnabled) tool.name,
  };

  static void apply(AiConfig? config, List<AiTool> tools) {
    final known = tools.map((tool) => tool.name).toSet();
    final stored = config?.enabledTools;
    if (stored == null) {
      enabled.value = defaultsFor(tools);
    } else {
      enabled.value = stored.where(known.contains).toSet();
    }
    sensitivePaths.value = config?.sensitivePaths == null
        ? defaultsForSensitivePaths
        : List<String>.from(config!.sensitivePaths!);
  }
}
