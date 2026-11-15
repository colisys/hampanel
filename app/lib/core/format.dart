String formatBytes(num? value) {
  var bytes = (value ?? 0).toDouble();
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var unit = 0;
  while (bytes >= 1024 && unit < units.length - 1) {
    bytes /= 1024;
    unit++;
  }
  return unit == 0
      ? '${bytes.toStringAsFixed(0)} ${units[unit]}'
      : '${bytes.toStringAsFixed(1)} ${units[unit]}';
}

String formatDuration(num? seconds) {
  final total = (seconds ?? 0).toInt();
  final days = total ~/ 86400;
  final hours = (total % 86400) ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  if (days > 0) return '$days 天 $hours 小时';
  if (hours > 0) return '$hours 小时 $minutes 分';
  return '$minutes 分';
}

String formatPercent(num? value) => '${(value ?? 0).toStringAsFixed(1)}%';

String formatDateTime(int? millis) {
  if (millis == null || millis <= 0) return '-';
  return formatTimestamp(millis);
}

/// 统一的本地时间格式化（操作系统默认时区），用于所有时间戳展示。
/// 接受 epoch 秒/毫秒、ISO-8601 字符串或数字字符串。
String formatTimestamp(dynamic value) {
  final date = _toLocalTime(value);
  if (date == null) return '-';
  String two(int part) => part.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}:${two(date.second)}';
}

DateTime? _toLocalTime(dynamic value) {
  if (value == null) return null;
  if (value is num) {
    final millis = value.abs() < 100000000000
        ? (value * 1000).round()
        : value.round();
    return DateTime.fromMillisecondsSinceEpoch(millis);
  }
  final text = value.toString().trim();
  if (text.isEmpty) return null;
  final epoch = int.tryParse(text);
  if (epoch != null) return _toLocalTime(epoch);
  return DateTime.tryParse(text)?.toLocal();
}

/// 把日志行首的 ISO-8601 时间戳（journalctl 等）转换为本地时间，
/// 避免同一界面里出现 UTC、epoch 与本地时间混排。
String localizeLogTimestamps(String text) {
  final pattern = RegExp(
    r'^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}))',
  );
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final match = pattern.firstMatch(lines[i]);
    if (match == null) continue;
    final parsed = DateTime.tryParse(match.group(1)!)?.toLocal();
    if (parsed == null) continue;
    lines[i] =
        '${formatTimestamp(parsed.toIso8601String())}'
        '${lines[i].substring(match.end)}';
  }
  return lines.join('\n');
}
