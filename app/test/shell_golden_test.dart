import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/core/host_store.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/shell/panel_shell.dart';
import 'package:hampanel/ui/theme.dart';

Future<void> _loadFont(String family, String path) async {
  final bytes = File(path).readAsBytesSync();
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(bytes)));
  await loader.load();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late String caPem;
  late String certPem;
  late String keyPem;
  late Directory dir;

  setUpAll(() async {
    await _loadFont(
      'Noto Sans CJK SC',
      '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    );
    await _loadFont(
      'DejaVu Sans Mono',
      '/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf',
    );
    dir = await Directory.systemTemp.createTemp('hampanel-golden');
    addTearDown(() => dir.delete(recursive: true));
    final result = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-keyout',
      '${dir.path}/key.pem',
      '-out',
      '${dir.path}/cert.pem',
      '-days',
      '1',
      '-subj',
      '/CN=golden',
    ]);
    if (result.exitCode != 0) {
      fail('openssl failed: ${result.stderr}');
    }
    certPem = await File('${dir.path}/cert.pem').readAsString();
    keyPem = await File('${dir.path}/key.pem').readAsString();
    caPem = certPem;
  });

  late PanelSession session;
  late String hostId;

  setUp(() async {
    final store = await HostStore.open(directory: dir);
    addTearDown(store.close);
    final enrollment = Enrollment.fromText('''
{
  "schema": 1,
  "product": "Hampanel",
  "endpoint": "127.0.0.1:8443",
  "entry_prefix": "/secret",
  "ca_pem": "${caPem.replaceAll('\n', '\\n')}",
  "client_cert_pem": "${certPem.replaceAll('\n', '\\n')}",
  "client_key_pem": "${keyPem.replaceAll('\n', '\\n')}",
  "ca_sha256": "aa",
  "server_sha256": "bb",
  "client_cn": "cn",
  "created_at": "now"
}
''');
    final host =
        store.upsert(alias: 'golden', enrollment: enrollment, activate: true);
    session = PanelSession(enrollment, store);
    hostId = host.id;
  });

  testWidgets('shell header aligns with top bar', (tester) async {
    setHampanelBrightness(Brightness.dark);
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildHampanelTheme(),
        home: PanelScope(
          session: session,
          child: PanelShell(
            sessionKey: hostId,
            onLogout: () async {},
            onSwitchHost: (_) async {},
          ),
        ),
      ),
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/shell_dark.png'),
    );
  });
}
