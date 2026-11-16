import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';
import 'enrollment.dart';

class ConversationEntry {
  ConversationEntry({required this.role, required this.text});

  final String role;
  String text;

  Map<String, dynamic> toJson() => {'role': role, 'text': text};

  factory ConversationEntry.fromJson(Map<String, dynamic> json) =>
      ConversationEntry(
        role: json['role'] as String? ?? 'assistant',
        text: json['text'] as String? ?? '',
      );
}

class AiConversation {
  AiConversation({
    required this.id,
    required this.title,
    required this.updatedAt,
    List<ConversationEntry>? entries,
    List<Map<String, dynamic>>? chatHistory,
    List<Map<String, dynamic>>? responsesInput,
  }) : entries = entries ?? [],
       chatHistory = chatHistory ?? [],
       responsesInput = responsesInput ?? [];

  final String id;
  String title;
  int updatedAt;
  final List<ConversationEntry> entries;
  final List<Map<String, dynamic>> chatHistory;
  final List<Map<String, dynamic>> responsesInput;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updated_at': updatedAt,
    'entries': [for (final entry in entries) entry.toJson()],
    'chat_history': chatHistory,
    'responses_input': responsesInput,
  };

  factory AiConversation.fromJson(Map<String, dynamic> json) => AiConversation(
    id: json['id'] as String? ?? _newId(),
    title: json['title'] as String? ?? '新对话',
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
    entries: ((json['entries'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ConversationEntry.fromJson)
        .toList(),
    chatHistory: ((json['chat_history'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(),
    responsesInput: ((json['responses_input'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList(),
  );
}

/// 对话保存在管理端配置目录，和主机凭据分开；只保留最近 30 个会话。
class ConversationStore {
  static const maxConversations = 30;

  static File get _file {
    final directory = Enrollment.configDirectory();
    return File(
      '${directory.path}${Platform.pathSeparator}ai_conversations.json',
    );
  }

  static Future<List<AiConversation>> load() async {
    try {
      if (!await _file.exists()) return [];
      final raw = await _file.readAsString();
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      final list = decoded
          .whereType<Map<String, dynamic>>()
          .map(AiConversation.fromJson)
          .toList();
      list.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return list;
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<AiConversation> conversations) async {
    try {
      final sorted = [...conversations]
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      final trimmed = sorted.take(maxConversations).toList();
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        jsonEncode([for (final item in trimmed) item.toJson()]),
      );
      if (!Platform.isWindows) {
        await restrictToOwner(_file);
      }
    } catch (_) {
      // 会话持久化失败不影响当前对话。
    }
  }
}

String newConversationId() => _newId();

String _newId() =>
    DateTime.now().microsecondsSinceEpoch.toRadixString(36) +
    (DateTime.now().millisecond % 1000).toString();
