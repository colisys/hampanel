import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/log_parse.dart';

void main() {
  test('parses ISO timestamps and severity', () {
    final line = LogParser.parseLine(
      '2026-11-18T15:04:05Z error: upstream failed',
    );
    expect(line.timestamp, isNotNull);
    expect(line.timestamp!.toUtc().hour, 15);
    expect(line.severity, LogSeverity.error);
  });

  test('parses nginx access timestamps in their offset', () {
    final line = LogParser.parseLine(
      '203.0.113.4 - - [18/Nov/2026:15:04:05 +0800] "GET / HTTP/1.1" 200',
    );
    expect(line.timestamp, isNotNull);
    expect(line.severity, LogSeverity.info);
  });

  test('parses syslog warnings', () {
    final line = LogParser.parseLine('Nov 18 15:04:05 host sshd[1]: warning: x');
    expect(line.timestamp, isNotNull);
    expect(line.severity, LogSeverity.warning);
  });

  test('parses JSON log level and epoch ts', () {
    final line = LogParser.parseLine(
      '{"ts":1763468645.5,"level":"error","msg":"blocked"}',
    );
    expect(line.timestamp, isNotNull);
    expect(line.severity, LogSeverity.error);
  });

  test('keeps unknown timestamps null', () {
    final line = LogParser.parseLine('plain text without a timestamp');
    expect(line.timestamp, isNull);
  });
}
