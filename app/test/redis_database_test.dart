import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/databases/database_dialogs.dart';
import 'package:hampanel/features/databases/databases_page.dart';
import 'package:hampanel/ui/layout.dart';
import 'package:hampanel/ui/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:xterm/xterm.dart';

class _Session extends ChangeNotifier implements PanelSession {
  @override
  final api = _Api();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Api implements ApiClient {
  final reads = <String>[];
  final terminals = <String?>[];

  @override
  Future<dynamic> getJson(String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    reads.add(path);
    return <String, dynamic>{
      'items': [
        {'id': 'r-1', 'name': 'cache', 'engine': 'redis', 'mode': 'host',
          'host': 'localhost', 'port': 6379},
      ],
    };
  }

  @override
  Future<WebSocket> openTerminal({
    required int cols,
    required int rows,
    String? redisId,
  }) {
    terminals.add(redisId);
    return Completer<WebSocket>().future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('Redis registration submits port 6379 without an ACL user', (tester) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await databaseDialog(context, '实例', '保存', ['port', 'user'], instance: true);
        },
        child: const Text('打开'),
      ),
    ))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MySQL').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Redis').last);
    await tester.pumpAndSettle();
    expect(find.text('6379'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result?['engine'], 'redis');
    expect(result?['port'], 6379);
    expect(result?['user'], '');
    expect(result?['mode'], 'host');
  });

  testWidgets('phone footer stretches and registration is docked', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(PanelScope(session: _Session(), child: const MaterialApp(home: Scaffold(body: DatabasesPage()))));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ActionDock)).width, 390);
    expect(tester.getSize(find.byType(SubNavMenu)).width, 390 - 32);
    expect(find.descendant(of: find.byType(ActionDock), matching: find.text('登记实例')), findsOneWidget);
    await tester.tap(find.byType(SubNavMenu));
    await tester.pumpAndSettle();
    await tester.tap(find.text('SQLite').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('登记实例'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('受管主机上的 SQLite 文件绝对路径'), findsOneWidget);
    expect(find.text('连接方式'), findsNothing);
  });

  testWidgets('opening Redis connects xterm without loading SQL data', (tester) async {
    final session = _Session();
    final api = session.api as _Api;
    await tester.pumpWidget(PanelScope(session: session, child: const MaterialApp(
      home: Scaffold(body: DatabasesPage()),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('cache'));
    await tester.pump();
    await tester.pump();
    expect(find.byType(TerminalView), findsOneWidget);
    expect(api.terminals, ['r-1']);
    expect(api.reads, ['/api/v1/databases/instances']);
  });
}
