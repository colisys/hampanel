import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/core/host_store.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/hosts/hosts_page.dart';
import 'package:hampanel/ui/theme.dart';

String _bundle(String caPem, String certPem, String keyPem) => jsonEncode({
  'schema': 1,
  'product': 'Hampanel',
  'endpoint': '203.0.113.10:8443',
  'entry_prefix': '/sA',
  'ca_pem': caPem,
  'client_cert_pem': certPem,
  'client_key_pem': keyPem,
  'ca_sha256': 'aa',
  'server_sha256': 'sa',
  'client_cn': 'hampanel-a',
  'created_at': 'now',
});

void main() {
  late String caPem;
  late String certPem;
  late String keyPem;
  late Directory pki;

  setUpAll(() async {
    pki = Directory.systemTemp.createTempSync('hampanel-hosts-pki');
    addTearDown(() {
      if (pki.existsSync()) pki.deleteSync(recursive: true);
    });
    final result = await Process.run('openssl', [
      'req', '-x509', '-newkey', 'rsa:2048', '-nodes',
      '-keyout', '${pki.path}/key.pem',
      '-out', '${pki.path}/cert.pem',
      '-days', '1', '-subj', '/CN=hosts-test',
    ]);
    if (result.exitCode != 0) {
      fail('openssl failed: ${result.stderr}');
    }
    caPem = File('${pki.path}/cert.pem').readAsStringSync();
    certPem = caPem;
    keyPem = File('${pki.path}/key.pem').readAsStringSync();
  });

  testWidgets('editing a host closes the dialog', (tester) async {
    final dir = Directory.systemTemp.createTempSync('hampanel-hosts');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    late HostStore store;
    await tester.runAsync(() async {
      store = await HostStore.open(directory: dir);
      final enrollment = Enrollment.fromText(
        _bundle(caPem, certPem, keyPem),
      );
      store.upsert(alias: 'aliyun', enrollment: enrollment, activate: true);
    });
    addTearDown(store.close);

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHampanelTheme(),
        home: _Harness(store: store, enrollment: Enrollment.fromText(
          _bundle(caPem, certPem, keyPem),
        )),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    expect(find.text('编辑主机'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'aliyun-2');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(find.text('编辑主机'), findsNothing);
    expect(store.active()?.alias, 'aliyun-2');
  });
}

class _Harness extends StatefulWidget {
  const _Harness({required this.store, required this.enrollment});

  final HostStore store;
  final Enrollment enrollment;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late PanelSession _session = PanelSession(widget.enrollment, widget.store);

  Future<void> _switch(HostRecord host) async {
    _session.dispose();
    setState(() => _session = PanelSession(host.enrollment, widget.store));
  }

  @override
  Widget build(BuildContext context) {
    return PanelScope(
      session: _session,
      child: Scaffold(
        body: HostsPage(onSwitchHost: _switch),
      ),
    );
  }
}
