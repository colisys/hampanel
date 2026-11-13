import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/app.dart';
import 'package:hampanel/core/enrollment.dart';

void main() {
  test('enrollment parses generated bundle', () {
    final enrollment = Enrollment.fromText('''
{
  "schema": 1,
  "endpoint": "127.0.0.1:8443",
  "entry_prefix": "/secret123",
  "ca_pem": "-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----",
  "client_cert_pem": "-----BEGIN CERTIFICATE-----\\nMIIB\\n-----END CERTIFICATE-----",
  "client_key_pem": "-----BEGIN PRIVATE KEY-----\\nMIIB\\n-----END PRIVATE KEY-----",
  "ca_sha256": "aa",
  "server_sha256": "bb",
  "client_cn": "hampanel-client-test",
  "created_at": "2026-01-01T00:00:00Z"
}
''');
    expect(enrollment.endpoint, '127.0.0.1:8443');
    expect(enrollment.clientCn, 'hampanel-client-test');
    expect(enrollment.entryPrefix, '/secret123');
  });

  testWidgets('login page is shown without enrollment', (tester) async {
    await tester.pumpWidget(const HampanelApp());
    await tester.pump();
    expect(find.text('导入注册凭据'), findsOneWidget);
  });
}
