import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/features/auth/login_page.dart';

const enrollmentSample = '''
{
  "schema": 1,
  "product": "Hampanel",
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
''';

void main() {
  test('enrollment parses generated bundle', () {
    final enrollment = Enrollment.fromText(enrollmentSample);
    expect(enrollment.endpoint, '127.0.0.1:8443');
    expect(enrollment.clientCn, 'hampanel-client-test');
    expect(enrollment.entryPrefix, '/secret123');
  });

  test('enrollment round-trips every field through save/load', () async {
    final dir = await Directory.systemTemp.createTemp('hampanel-test');
    addTearDown(() => dir.delete(recursive: true));
    final original = Enrollment.fromText(enrollmentSample);
    final file = File('${dir.path}/enrollment.json');
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(original.toJson()),
    );
    final loaded = Enrollment.fromText(await file.readAsString());
    expect(loaded.toJson(), original.toJson());
    final source = jsonDecode(enrollmentSample) as Map<String, dynamic>;
    expect(loaded.toJson(), source);
  });

  testWidgets('login page is shown without enrollment', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: LoginPage(onEnrolled: (_, {alias}) async {})),
    );
    await tester.pumpAndSettle();
    expect(find.text('导入注册凭据'), findsOneWidget);
  });
}
