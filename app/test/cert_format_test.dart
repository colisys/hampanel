import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/format.dart';

void main() {
  test('fingerprints are normalized and grouped', () {
    expect(formatFingerprint('C0:E1:E4:2F:4B:CF:D6:D7'), 'c0e1 e42f 4bcf d6d7');
    expect(formatFingerprint(''), '未提供');
    expect(normalizeFingerprint('AA:bb cc'), 'aabbcc');
  });

  test('audit entries render local-time lines', () {
    final line = formatAuditEntry({
      'at': '2026-11-16T03:56:39Z',
      'peer': 'hampanel-client-abc',
      'method': 'POST',
      'path': '/api/v1/files/upload',
      'status': 200,
      'duration_ms': 5,
    });
    expect(line, contains('POST /api/v1/files/upload -> 200 (5 ms)'));
    expect(line, contains('hampanel-client-abc'));
    expect(line, isNot(contains('T03:56:39Z')));
  });
}
