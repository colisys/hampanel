import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/format.dart';

void main() {
  test('formats epoch seconds and milliseconds in local time', () {
    final local = DateTime(2026, 11, 15, 22, 40, 10);
    final seconds = local.millisecondsSinceEpoch ~/ 1000;
    expect(formatTimestamp(seconds), '2026-11-15 22:40:10');
    expect(
      formatTimestamp(local.millisecondsSinceEpoch),
      '2026-11-15 22:40:10',
    );
  });

  test('parses ISO timestamps and converts to local time', () {
    final utc = DateTime.utc(2026, 11, 15, 14, 40, 10);
    final local = utc.toLocal();
    final expected =
        '${local.year.toString().padLeft(4, '0')}-'
        '${local.month.toString().padLeft(2, '0')}-'
        '${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:'
        '${local.minute.toString().padLeft(2, '0')}:'
        '${local.second.toString().padLeft(2, '0')}';
    expect(formatTimestamp(utc.toIso8601String()), expected);
  });

  test('rewrites journald prefixes to local time', () {
    final input = '2026-11-15T14:43:08+0000 host sshd[1]: hello';
    final output = localizeLogTimestamps(input);
    expect(output.endsWith(' host sshd[1]: hello'), isTrue);
    expect(output.contains('T14:43:08'), isFalse);
  });
}
