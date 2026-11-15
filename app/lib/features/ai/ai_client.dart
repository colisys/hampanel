import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/ai_config.dart';

class AiException implements Exception {
  AiException(this.statusCode, this.body);
  final int statusCode;
  final String body;
  @override
  String toString() => 'AI 请求失败 ($statusCode): ${_message()}';

  String _message() {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map<String, dynamic>) {
        final error = decoded['error'];
        if (error is Map<String, dynamic>) {
          return error['message'] as String? ?? body;
        }
      }
    } catch (_) {}
    return body.length > 600 ? body.substring(0, 600) : body;
  }
}

class AiToolCall {
  AiToolCall({
    required this.id,
    required this.name,
    required this.argumentsRaw,
    required this.arguments,
  });

  final String id;
  final String name;
  final String argumentsRaw;
  final Map<String, dynamic> arguments;
}

class AiReply {
  AiReply({
    required this.text,
    required this.toolCalls,
    required this.assistantMessage,
    required this.outputItems,
  });

  final String? text;
  final List<AiToolCall> toolCalls;
  final Map<String, dynamic>? assistantMessage;
  final List<Map<String, dynamic>> outputItems;
}

class AiClient {
  Future<AiReply> chatCompletions(
    AiConfig config,
    String apiKey,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
  ) async {
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
    };
    final json = await _post(config, apiKey, 'chat/completions', body);
    final choices = json['choices'];
    if (choices is! List || choices.isEmpty) {
      throw AiException(200, '响应中没有 choices');
    }
    final message = (choices.first as Map<String, dynamic>)['message'];
    if (message is! Map<String, dynamic>) {
      throw AiException(200, '响应中没有 message');
    }

    final calls = <AiToolCall>[];
    final rawCalls = message['tool_calls'];
    if (rawCalls is List) {
      for (final raw in rawCalls.whereType<Map<String, dynamic>>()) {
        final function = raw['function'];
        if (function is! Map<String, dynamic>) continue;
        final name = function['name'] as String? ?? '';
        final argumentsRaw = function['arguments'] as String? ?? '{}';
        calls.add(
          AiToolCall(
            id: raw['id'] as String? ?? name,
            name: name,
            argumentsRaw: argumentsRaw,
            arguments: _parseArguments(argumentsRaw),
          ),
        );
      }
    }

    final content = message['content'];
    return AiReply(
      text: content is String && content.trim().isNotEmpty
          ? content.trim()
          : null,
      toolCalls: calls,
      assistantMessage: message,
      outputItems: const [],
    );
  }

  Future<AiReply> responses(
    AiConfig config,
    String apiKey,
    String instructions,
    List<Map<String, dynamic>> input,
    List<Map<String, dynamic>> tools,
  ) async {
    final body = <String, dynamic>{
      'model': config.model,
      'instructions': instructions,
      'input': input,
      if (tools.isNotEmpty) 'tools': tools,
    };
    final json = await _post(config, apiKey, 'responses', body);
    final output = json['output'];
    if (output is! List) {
      throw AiException(200, '响应中没有 output');
    }

    final calls = <AiToolCall>[];
    final outputItems = <Map<String, dynamic>>[];
    final textParts = <String>[];
    for (final raw in output.whereType<Map<String, dynamic>>()) {
      outputItems.add(raw);
      final type = raw['type'] as String? ?? '';
      if (type == 'function_call') {
        final name = raw['name'] as String? ?? '';
        final argumentsRaw = raw['arguments'] as String? ?? '{}';
        calls.add(
          AiToolCall(
            id: raw['call_id'] as String? ?? raw['id'] as String? ?? name,
            name: name,
            argumentsRaw: argumentsRaw,
            arguments: _parseArguments(argumentsRaw),
          ),
        );
      } else if (type == 'message') {
        final content = raw['content'];
        if (content is List) {
          for (final part in content.whereType<Map<String, dynamic>>()) {
            if (part['type'] == 'output_text') {
              final text = part['text'] as String? ?? '';
              if (text.isNotEmpty) textParts.add(text);
            }
          }
        }
      }
    }

    return AiReply(
      text: textParts.isEmpty ? null : textParts.join('\n').trim(),
      toolCalls: calls,
      assistantMessage: null,
      outputItems: outputItems,
    );
  }

  /// Chat Completions 的流式版本：逐段回调文本增量，结束时返回完整的
  /// tool_calls，调用方可以继续原有的工具循环。
  Future<AiReply> chatCompletionsStream(
    AiConfig config,
    String apiKey,
    List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>> tools,
    void Function(String delta) onDelta,
  ) async {
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      if (tools.isNotEmpty) 'tools': tools,
      if (tools.isNotEmpty) 'tool_choice': 'auto',
      'stream': true,
    };
    final uri = _endpoint(config, 'chat/completions');
    final client = _client();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set('authorization', 'Bearer $apiKey');
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 180),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final raw = await utf8.decoder.bind(response).join();
        throw AiException(response.statusCode, raw);
      }

      final text = StringBuffer();
      final calls = <int, _PartialCall>{};
      final lines = response
          .transform(utf8.decoder)
          .transform(const LineSplitter());
      await for (final line in lines) {
        if (!line.startsWith('data:')) continue;
        final payload = line.substring(5).trim();
        if (payload.isEmpty) continue;
        if (payload == '[DONE]') break;
        Map<String, dynamic> chunk;
        try {
          final decoded = jsonDecode(payload);
          if (decoded is! Map<String, dynamic>) continue;
          chunk = decoded;
        } catch (_) {
          continue;
        }
        final choices = chunk['choices'];
        if (choices is! List || choices.isEmpty) continue;
        final choice = choices.first;
        if (choice is! Map<String, dynamic>) continue;
        final delta = choice['delta'];
        if (delta is! Map<String, dynamic>) continue;
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          text.write(content);
          onDelta(content);
        }
        final toolDeltas = delta['tool_calls'];
        if (toolDeltas is List) {
          for (final raw in toolDeltas.whereType<Map<String, dynamic>>()) {
            final index = (raw['index'] as num?)?.toInt() ?? calls.length;
            final call = calls.putIfAbsent(index, _PartialCall.new);
            final id = raw['id'];
            if (id is String && id.isNotEmpty) call.id = id;
            final function = raw['function'];
            if (function is Map<String, dynamic>) {
              final name = function['name'];
              if (name is String && name.isNotEmpty) call.name = name;
              final arguments = function['arguments'];
              if (arguments is String) call.arguments.write(arguments);
            }
          }
        }
      }

      final indexes = calls.keys.toList()..sort();
      final toolCalls = <AiToolCall>[];
      final rawCalls = <Map<String, dynamic>>[];
      for (final index in indexes) {
        final partial = calls[index]!;
        if (partial.name.isEmpty) continue;
        final argumentsRaw = partial.arguments.toString();
        toolCalls.add(
          AiToolCall(
            id: partial.id ?? partial.name,
            name: partial.name,
            argumentsRaw: argumentsRaw,
            arguments: _parseArguments(argumentsRaw),
          ),
        );
        rawCalls.add({
          'id': partial.id ?? partial.name,
          'type': 'function',
          'function': {'name': partial.name, 'arguments': argumentsRaw},
        });
      }

      final content = text.toString();
      return AiReply(
        text: content.trim().isEmpty ? null : content.trim(),
        toolCalls: toolCalls,
        assistantMessage: {
          'role': 'assistant',
          'content': content,
          if (rawCalls.isNotEmpty) 'tool_calls': rawCalls,
        },
        outputItems: const [],
      );
    } finally {
      client.close(force: true);
    }
  }

  Uri _endpoint(AiConfig config, String suffix) {
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.parse('$base/$suffix');
    if (uri.scheme != 'https' && uri.scheme != 'http') {
      throw AiException(0, 'Base URL 必须是 http(s) 地址');
    }
    return uri;
  }

  HttpClient _client() => HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 30);

  Future<Map<String, dynamic>> _post(
    AiConfig config,
    String apiKey,
    String suffix,
    Map<String, dynamic> body,
  ) async {
    final uri = _endpoint(config, suffix);
    final client = _client();
    try {
      final request = await client.postUrl(uri);
      request.headers.contentType = ContentType.json;
      request.headers.set('authorization', 'Bearer $apiKey');
      request.write(jsonEncode(body));
      final response = await request.close().timeout(
        const Duration(seconds: 150),
      );
      final raw = await response.transform(utf8.decoder).join();
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw AiException(response.statusCode, raw);
      }
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw AiException(response.statusCode, '响应不是 JSON 对象');
      }
      return decoded;
    } finally {
      client.close(force: true);
    }
  }

  Map<String, dynamic> _parseArguments(String raw) {
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> ? decoded : {};
    } catch (_) {
      return {};
    }
  }
}

Map<String, dynamic> chatToolSpec(Map<String, dynamic> tool) => {
  'type': 'function',
  'function': {
    'name': tool['name'],
    'description': tool['description'],
    'parameters': tool['parameters'],
  },
};

Map<String, dynamic> responsesToolSpec(Map<String, dynamic> tool) => {
  'type': 'function',
  'name': tool['name'],
  'description': tool['description'],
  'parameters': tool['parameters'],
};

class _PartialCall {
  String? id;
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
