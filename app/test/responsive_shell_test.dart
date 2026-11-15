import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/core/host_store.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/shell/panel_shell.dart';
import 'package:hampanel/ui/theme.dart';
import 'package:hampanel/ui/widgets.dart';

final _opensslReady = Process.runSync('openssl', ['version']).exitCode == 0;

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
    _bundle = jsonEncode({
      'endpoint': '127.0.0.1:8443',
      'entry_prefix': '/test',
      'ca_pem': read('cert.pem'),
      'client_cert_pem': read('client-cert.pem'),
      'client_key_pem': read('client-key.pem'),
    });
  });

  testWidgets(
    'narrow shell collapses the sidebar into a drawer',
    skip: !_opensslReady,
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
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
    },
  );

  testWidgets('dialog bodies clamp to the screen width', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(360, 800)),
          child: Center(
            child: DialogBody(maxWidth: 900, child: const Text('body')),
          ),
        ),
      ),
    );
    final size = tester.getSize(find.byType(DialogBody));
    expect(size.width, 312);
  });
}
