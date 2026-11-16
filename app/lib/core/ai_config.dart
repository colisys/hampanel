import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';

class AiConfig {
  AiConfig({
    required this.protocol,
    required this.baseUrl,
    required this.model,
    this.enabledTools,
    this.sensitivePaths,
  });

  /// chat_completions or responses
  String protocol;
  String baseUrl;
  String model;

  /// null means "use built-in defaults"; an empty list disables all tools.
  List<String>? enabledTools;

  /// Paths (or directories) whose AI reads require human approval.
  /// null means "use built-in defaults".
  List<String>? sensitivePaths;

  static const defaultBaseUrl = 'https://api.openai.com/v1';
  static const defaultModel = 'gpt-4.1-mini';

  factory AiConfig.defaults() => AiConfig(
    protocol: 'chat_completions',
    baseUrl: defaultBaseUrl,
    model: defaultModel,
  );

  factory AiConfig.fromJson(Map<String, dynamic> json) => AiConfig(
    protocol: json['protocol'] as String? ?? 'chat_completions',
    baseUrl: json['base_url'] as String? ?? defaultBaseUrl,
    model: json['model'] as String? ?? defaultModel,
    enabledTools: (json['enabled_tools'] as List<dynamic>?)
        ?.whereType<String>()
        .toList(),
  );

  Map<String, dynamic> toJson() => {
    'protocol': protocol,
    'base_url': baseUrl,
    'model': model,
    'enabled_tools': enabledTools,
  };

  static Directory _dir() => AppPaths.configDirectory();

  static File get _file =>
      File('${_dir().path}${Platform.pathSeparator}ai_config.json');

  static Future<AiConfig?> load() async {
    try {
      if (!await _file.exists()) return null;
      final raw = await _file.readAsString();
      return AiConfig.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    await _dir().create(recursive: true);
    await _file.writeAsString(jsonEncode(toJson()));
    if (!Platform.isWindows) {
      await restrictToOwner(_file);
    }
  }

  static Future<void> delete() async {
    try {
      if (await _file.exists()) await _file.delete();
    } catch (_) {}
  }
}
