import 'package:material_ui/material_ui.dart';

enum LogSeverity {
  error('错误', Color(0xFF8E1B1B)),
  warning('警告', Color(0xFF9A6100)),
  info('信息', Color(0xFF3B362E)),
  debug('调试', Color(0xFF6B6457));

  const LogSeverity(this.label, this.color);

  final String label;
  final Color color;
}

class LogLine {
  const LogLine({
    required this.raw,
    this.number = 0,
    this.timestamp,
    this.severity = LogSeverity.info,
  });

  final String raw;
  final int number;
  final DateTime? timestamp;
  final LogSeverity severity;
}

/// Parses the timestamp/severity formats used by audit, journal, nginx and
/// Caddy logs. Unknown timestamps are kept as null and are only excluded when a
/// time range is explicitly selected.
class LogParser {
  static final RegExp _iso = RegExp(
    r'^(\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)',
  );
  static final RegExp _isoAnywhere = RegExp(
    r'\b(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2}))\b',
  );
  static final RegExp _syslog = RegExp(
    r'^([A-Z][a-z]{2})\s+(\d{1,2})\s+(\d{2}):(\d{2}):(\d{2})',
  );
  static final RegExp _nginx = RegExp(
    r'\[(\d{2})/([A-Za-z]{3})/(\d{4}):(\d{2}):(\d{2}):(\d{2})\s+([+-]\d{4})\]',
  );
  static final RegExp _jsonTs = RegExp(
    r'"(?:ts|time|timestamp)"\s*:\s*"?([0-9]+(?:\.[0-9]+)?|[^",}]+)"?',
  );
  static final RegExp _jsonLevel = RegExp(
    r'"(?:level|severity)"\s*:\s*"([^"]+)"',
    caseSensitive: false,
  );

  static const _months = {
    'Jan': 1,
    'Feb': 2,
    'Mar': 3,
    'Apr': 4,
    'May': 5,
    'Jun': 6,
    'Jul': 7,
    'Aug': 8,
    'Sep': 9,
    'Oct': 10,
    'Nov': 11,
    'Dec': 12,
  };

  static List<LogLine> parse(String content) {
    if (content.isEmpty) return const [];
    final lines = content.split('\n');
    return [
      for (var i = 0; i < lines.length; i++) parseLine(lines[i], i + 1),
    ];
  }

  static LogLine parseLine(String raw, [int number = 0]) {
    return LogLine(
      raw: raw,
      number: number,
      timestamp: _timestamp(raw),
      severity: _severity(raw),
    );
  }

  static DateTime? _timestamp(String raw) {
    final iso = _iso.firstMatch(raw);
    if (iso != null) {
      final parsed = DateTime.tryParse(iso.group(1)!);
      if (parsed != null) return parsed.toLocal();
    }

    final json = _jsonTs.firstMatch(raw);
    if (json != null) {
      final value = json.group(1)!;
      final number = double.tryParse(value);
      if (number != null) {
        final millis = number.abs() < 100000000000
            ? (number * 1000).round()
            : number.round();
        return DateTime.fromMillisecondsSinceEpoch(millis);
      }
      final parsed = DateTime.tryParse(value);
      if (parsed != null) return parsed.toLocal();
    }

    final anywhere = _isoAnywhere.firstMatch(raw);
    if (anywhere != null) {
      final parsed = DateTime.tryParse(anywhere.group(1)!);
      if (parsed != null) return parsed.toLocal();
    }

    final nginx = _nginx.firstMatch(raw);
    if (nginx != null) {
      final month = _months[nginx.group(2)];
      if (month != null) {
        final offset = nginx.group(7)!;
        final local = DateTime(
          int.parse(nginx.group(3)!),
          month,
          int.parse(nginx.group(1)!),
          int.parse(nginx.group(4)!),
          int.parse(nginx.group(5)!),
          int.parse(nginx.group(6)!),
        );
        final sign = offset.startsWith('-') ? -1 : 1;
        final hours = int.parse(offset.substring(1, 3));
        final minutes = int.parse(offset.substring(3, 5));
        return local
            .subtract(Duration(hours: sign * hours, minutes: sign * minutes))
            .toLocal();
      }
    }

    final syslog = _syslog.firstMatch(raw);
    if (syslog != null) {
      final month = _months[syslog.group(1)];
      if (month != null) {
        final now = DateTime.now();
        var date = DateTime(
          now.year,
          month,
          int.parse(syslog.group(2)!),
          int.parse(syslog.group(3)!),
          int.parse(syslog.group(4)!),
          int.parse(syslog.group(5)!),
        );
        if (date.isAfter(now.add(const Duration(days: 1)))) {
          date = DateTime(
            now.year - 1,
            date.month,
            date.day,
            date.hour,
            date.minute,
            date.second,
          );
        }
        return date;
      }
    }

    return null;
  }

  static LogSeverity _severity(String raw) {
    final level = _jsonLevel.firstMatch(raw)?.group(1)?.toLowerCase();
    if (level != null) {
      if (level.contains('err') ||
          level.contains('fatal') ||
          level.contains('crit') ||
          level.contains('panic')) {
        return LogSeverity.error;
      }
      if (level.contains('warn')) return LogSeverity.warning;
      if (level.contains('debug') || level.contains('trace')) {
        return LogSeverity.debug;
      }
      return LogSeverity.info;
    }
    final lower = raw.toLowerCase();
    if (lower.contains('fatal') ||
        lower.contains('panic') ||
        lower.contains('critical') ||
        lower.contains('crit ') ||
        lower.contains('error') ||
        lower.contains('failed') ||
        lower.contains('failure')) {
      return LogSeverity.error;
    }
    if (lower.contains('warn')) return LogSeverity.warning;
    if (lower.contains('debug') || lower.contains('trace')) {
      return LogSeverity.debug;
    }
    return LogSeverity.info;
  }
}
