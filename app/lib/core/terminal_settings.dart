/// xterm 终端的外观偏好。只保存在管理端本地
/// （`client_settings.json` 的 `terminal` 字段），不随受控端同步。
class TerminalSettings {
  const TerminalSettings({
    this.fontSize = 13,
    this.lineHeight = 1.2,
    this.cursor = 'block',
    this.theme = 'follow',
  });

  static const double minFontSize = 10;
  static const double maxFontSize = 24;
  static const double minLineHeight = 1;
  static const double maxLineHeight = 1.6;

  /// block / underline / bar
  static const cursors = ['block', 'underline', 'bar'];

  /// follow（跟随面板外观）/ classic（xterm 经典深色）/ black（纯黑高对比）
  static const themes = ['follow', 'classic', 'black'];

  final double fontSize;
  final double lineHeight;
  final String cursor;
  final String theme;

  factory TerminalSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TerminalSettings();
    final size = (json['font_size'] as num?)?.toDouble() ?? 13;
    final height = (json['line_height'] as num?)?.toDouble() ?? 1.2;
    final cursor = json['cursor'];
    final theme = json['theme'];
    return TerminalSettings(
      fontSize: size.clamp(minFontSize, maxFontSize),
      lineHeight: height.clamp(minLineHeight, maxLineHeight),
      cursor: cursors.contains(cursor) ? cursor! as String : 'block',
      theme: themes.contains(theme) ? theme! as String : 'follow',
    );
  }

  Map<String, dynamic> toJson() => {
    'font_size': fontSize,
    'line_height': lineHeight,
    'cursor': cursor,
    'theme': theme,
  };

  TerminalSettings copyWith({
    double? fontSize,
    double? lineHeight,
    String? cursor,
    String? theme,
  }) {
    return TerminalSettings(
      fontSize: fontSize?.clamp(minFontSize, maxFontSize) ?? this.fontSize,
      lineHeight:
          lineHeight?.clamp(minLineHeight, maxLineHeight) ?? this.lineHeight,
      cursor: cursor ?? this.cursor,
      theme: theme ?? this.theme,
    );
  }
}
