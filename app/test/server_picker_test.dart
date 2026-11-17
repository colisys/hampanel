import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:hampanel/core/enrollment.dart';
import 'package:hampanel/core/host_store.dart';
import 'package:hampanel/features/auth/server_picker_page.dart';
import 'package:hampanel/ui/theme.dart';

const _bundle =
    '{"schema":1,"product":"Hampanel","endpoint":"203.0.113.10:8443",'
    '"entry_prefix":"/sA","ca_pem":"CA_A","client_cert_pem":"CERT_A",'
    '"client_key_pem":"KEY_A","ca_sha256":"aa","server_sha256":"beef",'
    '"client_cn":"hampanel-client-a","created_at":"now"}';

void main() {
  late Directory dir;
  late HostStore store;
  late HostRecord host;

  // Real file I/O cannot run inside testWidgets' fake-async zone.
  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('server-picker-test');
    store = await HostStore.open(directory: dir);
    host = store.upsert(
      alias: 'edge-01',
      enrollment: Enrollment.fromText(_bundle),
      activate: true,
    );
  });

  tearDownAll(() {
    store.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  testWidgets('lists saved servers and connects on tap', (tester) async {
    tester.view.physicalSize = const Size(360, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    HostRecord? connected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildHampanelTheme(),
        home: ServerPickerPage(
          store: store,
          activeId: host.id,
          onConnect: (record) async => connected = record,
          onEnrolled: (_, {alias}) async {},
          onDelete: (_) {},
        ),
      ),
    );
    await tester.pump();

    expect(find.text('edge-01'), findsOneWidget);
    expect(find.text('203.0.113.10:8443'), findsOneWidget);
    expect(find.text('上次连接'), findsOneWidget);

    await tester.tap(find.text('连接'));
    await tester.pump();
    await tester.pump();
    expect(connected?.id, host.id);
  });
}
