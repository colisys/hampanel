import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../core/ai_config.dart';
import '../../core/api_client.dart';
import '../../core/keychain.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'ai_client.dart';
import 'ai_tools.dart';

const _systemPrompt = '''
你是 Hampanel 服务器管理助手。规则：
1. 只能通过提供的工具操作服务器，禁止请求或执行任意 shell、脚本或系统命令。
2. 删除文件和目录只能通过 delete_path，内容会进入回收站，绝不可要求永久删除。
3. 所有修改类工具以及 read_file 都会由用户人工审核；如果用户拒绝，不要重复请求。
4. 不要猜测服务器状态，先调用只读工具确认。
5. 绝不能通过计划任务、写文件或其他方式执行任意 shell 命令。
5. 使用中文回答，简洁说明将要做什么和执行结果。
''';

class AiPage extends StatefulWidget {
  const AiPage({super.key, this.active = true});

  /// IndexedStack 会构建所有隐藏页；本地钥匙串只在页签激活时读取。
  final bool active;

  @override
  State<AiPage> createState() => _AiPageState();
}

class _AiPageState extends State<AiPage> {
  final _client = AiClient();
  final _inputController = TextEditingController();
  final _messages = <_ChatEntry>[];
  final _tools = buildAiTools();
  final _toolsByName = <String, AiTool>{};

  AiConfig? _config;
  bool _loading = true;
  bool _sending = false;
  bool _keyPresent = false;
  String? _keychainError;
  String? _error;
  String _status = '';

  List<Map<String, dynamic>> _chatHistory = [];
  List<Map<String, dynamic>> _responsesInput = [];

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    for (final tool in _tools) {
      _toolsByName[tool.name] = tool;
    }
    if (widget.active) _loadConfig();
  }

  @override
  void didUpdateWidget(covariant AiPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && !_configLoaded) {
      _loadConfig();
    }
  }

  bool _configLoaded = false;

  @override
  void dispose() {
    _inputController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    _configLoaded = true;
    final config = await AiConfig.load() ?? AiConfig.defaults();
    String? key;
    String? keyError;
    try {
      key = await AiKeychain.readKey();
    } catch (error) {
      keyError = error.toString();
    }
    if (!mounted) return;
    setState(() {
      _config = config;
      _keyPresent = key != null && key.isNotEmpty;
      _keychainError = keyError;
      _loading = false;
    });
    AiToolPreferences.apply(config, _tools);
  }

  Future<void> _openConfig() async {
    final config = _config ?? AiConfig.defaults();
    final baseController = TextEditingController(text: config.baseUrl);
    final modelController = TextEditingController(text: config.model);
    final keyController = TextEditingController();
    var protocol = config.protocol;

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('AI 配置'),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '配置保存在管理端；API 密钥只写入操作系统钥匙串，不写入配置文件。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 14),
                DropdownButtonFormField<String>(
                  initialValue: protocol,
                  decoration: const InputDecoration(labelText: '协议'),
                  items: const [
                    DropdownMenuItem(
                      value: 'chat_completions',
                      child: Text('Chat Completions (/chat/completions)'),
                    ),
                    DropdownMenuItem(
                      value: 'responses',
                      child: Text('Responses (/responses)'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value != null) setDialogState(() => protocol = value);
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: baseController,
                  decoration: const InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.openai.com/v1',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: modelController,
                  decoration: const InputDecoration(labelText: '模型'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: keyController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'API Key',
                    hintText: _keyPresent ? '已保存在系统钥匙串，留空保持不变' : '输入 API Key',
                  ),
                ),
                if (_keychainError != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    _keychainError!,
                    style: TextStyle(fontSize: 11.5, color: hampanelDanger),
                  ),
                ],
                if (_keyPresent) ...[
                  const SizedBox(height: 6),
                  Text(
                    '密钥已在系统钥匙串中。',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () async {
                try {
                  await AiKeychain.deleteKey();
                  if (context.mounted) Navigator.pop(context, false);
                  await _loadConfig();
                } catch (error) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(SnackBar(content: Text(error.toString())));
                  }
                }
              },
              child: const Text('清除密钥'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      final baseUrl = baseController.text.trim();
      final model = modelController.text.trim();
      final uri = Uri.tryParse(baseUrl);
      if (uri == null ||
          (uri.scheme != 'https' && uri.scheme != 'http') ||
          uri.host.isEmpty) {
        _toast('Base URL 必须是有效的 http(s) 地址');
      } else if (model.isEmpty) {
        _toast('模型不能为空');
      } else {
        final updated = AiConfig(
          protocol: protocol,
          baseUrl: baseUrl,
          model: model,
          enabledTools: AiToolPreferences.enabled.value.toList(),
          sensitivePaths: AiToolPreferences.sensitivePaths.value.toList(),
        );
        try {
          if (keyController.text.trim().isNotEmpty) {
            await AiKeychain.writeKey(keyController.text.trim());
          }
          await updated.save();
          await _loadConfig();
          _toast('AI 配置已保存');
        } catch (error) {
          _toast(error.toString());
        }
      }
    }

    baseController.dispose();
    modelController.dispose();
    keyController.dispose();
  }

  void _resetChat() {
    setState(() {
      _messages.clear();
      _chatHistory = [];
      _responsesInput = [];
      _error = null;
      _status = '';
    });
  }

  Future<void> _send() async {
    final text = _inputController.text.trim();
    if (text.isEmpty || _sending) return;
    final config = _config;
    if (config == null || !_keyPresent) {
      _toast('请先配置 Base URL、模型和 API Key');
      await _openConfig();
      return;
    }

    final key = await AiKeychain.readKey();
    if (key == null || key.isEmpty) {
      _toast('系统钥匙串中没有 API Key');
      return;
    }

    _inputController.clear();
    setState(() {
      _sending = true;
      _error = null;
      _status = 'AI 思考中…';
      _messages.add(_ChatEntry(role: 'user', text: text));
    });

    if (config.protocol == 'responses') {
      _responsesInput.add({'role': 'user', 'content': text});
    } else {
      if (_chatHistory.isEmpty) {
        _chatHistory.add({'role': 'system', 'content': _systemPrompt});
      }
      _chatHistory.add({'role': 'user', 'content': text});
    }

    final activeTools = _tools
        .where((tool) => AiToolPreferences.enabled.value.contains(tool.name))
        .toList();
    final activeNames = activeTools.map((tool) => tool.name).toSet();

    try {
      var iterations = 0;
      while (iterations < 6) {
        iterations += 1;
        final reply = config.protocol == 'responses'
            ? await _client.responses(
                config,
                key,
                _systemPrompt,
                _responsesInput,
                activeTools
                    .map((tool) => responsesToolSpec(_toolSchema(tool)))
                    .toList(),
              )
            : await _client.chatCompletions(
                config,
                key,
                _chatHistory,
                activeTools
                    .map((tool) => chatToolSpec(_toolSchema(tool)))
                    .toList(),
              );

        if (reply.text != null && reply.text!.isNotEmpty) {
          _appendAssistant(reply.text!);
        }

        if (reply.toolCalls.isEmpty) {
          if (config.protocol == 'responses') {
            for (final item in reply.outputItems) {
              if (item['type'] == 'message') _responsesInput.add(item);
            }
          } else if (reply.assistantMessage != null) {
            _chatHistory.add(reply.assistantMessage!);
          }
          break;
        }

        if (config.protocol == 'responses') {
          for (final item in reply.outputItems) {
            if (item['type'] == 'function_call') {
              _responsesInput.add({
                'type': 'function_call',
                'call_id': item['call_id'] ?? item['id'],
                'name': item['name'],
                'arguments': item['arguments'] ?? '{}',
              });
            }
          }
        } else if (reply.assistantMessage != null) {
          _chatHistory.add(reply.assistantMessage!);
        }

        for (final call in reply.toolCalls) {
          final tool = _toolsByName[call.name];
          String result;
          if (tool == null || !activeNames.contains(call.name)) {
            result = jsonEncode({
              'ok': false,
              'error': '工具未启用或不存在: ${call.name}',
            });
          } else if (tool.mutating ||
              (tool.requiresApproval?.call(call.arguments) ?? false)) {
            final approved = await _approve(tool, call.arguments);
            if (!approved) {
              result = jsonEncode({'ok': false, 'error': '用户拒绝执行该操作'});
              _appendToolNotice('已拒绝：${tool.summary(call.arguments)}');
            } else {
              result = await _executeTool(tool, call.arguments);
              _appendToolNotice('已执行：${tool.summary(call.arguments)}');
            }
          } else {
            result = await _executeTool(tool, call.arguments);
            _appendToolNotice('已读取：${tool.summary(call.arguments)}');
          }

          if (config.protocol == 'responses') {
            _responsesInput.add({
              'type': 'function_call_output',
              'call_id': call.id,
              'output': result,
            });
          } else {
            _chatHistory.add({
              'role': 'tool',
              'tool_call_id': call.id,
              'content': result,
            });
          }
          setState(() => _status = 'AI 思考中…');
        }
      }

      if (iterations >= 6) {
        _appendAssistant('已达到工具调用次数上限，请缩小任务范围后重试。');
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
      _appendAssistant('请求失败：$error');
    } finally {
      if (mounted) {
        setState(() {
          _sending = false;
          _status = '';
        });
      }
    }
  }

  Future<String> _executeTool(
    AiTool tool,
    Map<String, dynamic> arguments,
  ) async {
    try {
      return await tool.run(_api, arguments);
    } catch (error) {
      return jsonEncode({'ok': false, 'error': error.toString()});
    }
  }

  Future<bool> _approve(AiTool tool, Map<String, dynamic> arguments) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('AI 请求执行操作'),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                tool.summary(arguments),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: hampanelSurfaceAlt,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: hampanelBorder),
                ),
                child: SelectableText(
                  const JsonEncoder.withIndent('  ').convert(arguments),
                  style: monospace.copyWith(fontSize: 11.5),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                '所有修改类操作与敏感读取都需要人工审核。删除只会移动到回收站，不存在 shell 工具。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('批准执行'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  void _appendAssistant(String text) {
    if (!mounted) return;
    setState(() => _messages.add(_ChatEntry(role: 'assistant', text: text)));
  }

  void _appendToolNotice(String text) {
    if (!mounted) return;
    setState(() => _messages.add(_ChatEntry(role: 'tool', text: text)));
  }

  Map<String, dynamic> _toolSchema(AiTool tool) => {
    'name': tool.name,
    'description': tool.description,
    'parameters': tool.parameters,
  };

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: 'AI 助手',
          subtitle: '一句话管理服务器 · 白名单工具 · 关键操作人工审核',
          actions: [
            IconButton(
              tooltip: '配置',
              onPressed: _openConfig,
              icon: const Icon(Icons.settings_outlined, size: 20),
            ),
            IconButton(
              tooltip: '清空对话',
              onPressed: _resetChat,
              icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            ),
          ],
        ),
        if (_loading)
          const Expanded(child: LoadingView())
        else ...[
          if (_keychainError != null || !_keyPresent)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: hampanelSurfaceAlt,
                  borderRadius: BorderRadius.circular(3),
                  border: Border.all(color: hampanelWarning, width: 2),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.key_off_outlined,
                      size: 18,
                      color: hampanelWarning,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _keychainError ?? '尚未保存 API Key。密钥会存入系统钥匙串，不会写入配置文件。',
                        style: const TextStyle(fontSize: 12, height: 1.4),
                      ),
                    ),
                    TextButton(onPressed: _openConfig, child: const Text('配置')),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _messages.isEmpty
                ? EmptyState(
                    icon: Icons.auto_awesome,
                    title: '用一句话管理服务器',
                    message:
                        '例如：“检查磁盘占用，清理 /tmp 下超过 7 天的日志”，'
                        '或“列出最近失败的 systemd 服务”。\n'
                        'AI 只能调用系统设置中勾选的白名单工具，无法执行任意 shell；删除只会进入回收站，'
                        '所有修改操作均由你人工批准。',
                    action: _config == null
                        ? null
                        : TextButton(
                            onPressed: _openConfig,
                            child: const Text('配置 AI 服务'),
                          ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                    itemCount: _messages.length,
                    itemBuilder: (context, index) => _bubble(_messages[index]),
                  ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                _error!,
                style: TextStyle(fontSize: 11.5, color: hampanelDanger),
              ),
            ),
          Container(
            padding: const EdgeInsets.fromLTRB(24, 10, 24, 18),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: TextField(
                    controller: _inputController,
                    minLines: 1,
                    maxLines: 5,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(
                      hintText: '描述你想完成的操作…（Enter 发送）',
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                FilledButton.icon(
                  onPressed: _sending ? null : _send,
                  icon: _sending
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.send, size: 16),
                  label: Text(_sending ? _status : '发送'),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _bubble(_ChatEntry entry) {
    if (entry.role == 'tool') {
      return Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            Icon(Icons.build_outlined, size: 13, color: hampanelMuted),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.text,
                style: monospace.copyWith(fontSize: 10.5, color: hampanelMuted),
              ),
            ),
          ],
        ),
      );
    }

    final isUser = entry.role == 'user';
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 820),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser
              ? hampanelAccent.withValues(alpha: 0.12)
              : hampanelSurface,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: hampanelInk, width: 1.5),
        ),
        child: SelectableText(
          entry.text,
          style: TextStyle(
            fontSize: 12.5,
            height: 1.5,
            color: isUser ? hampanelInk : hampanelInkSoft,
          ),
        ),
      ),
    );
  }
}

class _ChatEntry {
  _ChatEntry({required this.role, required this.text});
  final String role;
  final String text;
}
