import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/core/host_store.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/shell/panel_shell.dart';
import 'package:hampanel/ui/theme.dart';

late String _bundle;

void main() {
  setUpAll(() {
    final dir = Directory.systemTemp.createTempSync('hampanel-shell-pki');
    addTearDown(() => dir.deleteSync(recursive: true));
    final key = '${dir.path}/key.pem';
    final cert = '${dir.path}/cert.pem';
    for (final args in [
      [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        cert,
        '-days',
        '1',
        '-subj',
        '/CN=hampanel-test-ca',
      ],
      [
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        '${dir.path}/client-key.pem',
        '-out',
        '${dir.path}/client-cert.pem',
        '-days',
        '1',
        '-subj',
        '/CN=hampanel-client-test',
        '-addext',
        'extendedKeyUsage=clientAuth',
      ],
    ]) {
      final result = Process.runSync('openssl', args);
      if (result.exitCode != 0) {
        throw StateError('openssl failed: ${result.stderr}');
      }
    }
    String read(String name) => File('${dir.path}/$name').readAsStringSync();
    _bundle =
        '{"endpoint":"127.0.0.1:8443","entry_prefix":"/test",'
        '"ca_pem":${_json(read('cert.pem'))},'
        '"client_cert_pem":${_json(read('client-cert.pem'))},'
        '"client_key_pem":${_json(read('client-key.pem'))}}';
  });

  testWidgets('narrow shell collapses the sidebar into a drawer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(480, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    late Directory dir;
    late HostStore store;
    late PanelSession session;
    await tester.runAsync(() async {
      dir = await Directory.systemTemp.createTemp('hampanel-shell');
      store = await HostStore.open(directory: dir);
      final enrollment = Enrollment.fromText(_bundle);
      store.upsert(alias: 'test', enrollment: enrollment, activate: true);
      session = PanelSession(enrollment, store);
    });
    addTearDown(() async {
      await tester.runAsync(() async {
        session.dispose();
        store.close();
        dir.deleteSync(recursive: true);
      });
    });

    await tester.pumpWidget(
      MaterialApp(
        theme: buildHampanelTheme(),
        home: PanelScope(
          session: session,
          child: PanelShell(
            sessionKey: 'test',
            onLogout: () async {},
            onSwitchHost: (_) async {},
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byIcon(Icons.menu), findsOneWidget);
    expect(find.text('AI 助手'), findsNothing);

    await tester.tap(find.byIcon(Icons.menu));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('AI 助手'), findsOneWidget);
  });
}

String _json(String value) {
  return '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n')}"';
}
