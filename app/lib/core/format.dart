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
  final date = DateTime.fromMillisecondsSinceEpoch(millis);
  String two(int value) => value.toString().padLeft(2, '0');
  return '${date.year}-${two(date.month)}-${two(date.day)} '
      '${two(date.hour)}:${two(date.minute)}';
}
