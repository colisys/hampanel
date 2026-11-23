import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/logs/logs_page.dart';
import 'package:material_ui/material_ui.dart';

class _Api extends Fake implements ApiClient {
  final queries = <Map<String, String>>[];

  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path == '/api/v1/logs/sources') {
      return {
        'sources': [
          {
            'id': 'panel',
            'label': '面板运行日志记录',
            'path': '/tmp/panel.log',
            'available': true,
          },
        ],
      };
    }
    if (path == '/api/v1/logs/tail') {
      queries.add(query!);
      return {
        'content':
            '2026-11-18T15:04:05 error: failed login\n'
            '2026-11-18T15:04:06 info: login ready',
      };
    }
    throw StateError('Unexpected request: $path');
  }
}

class _Session extends ChangeNotifier implements PanelSession {
  @override
  final _Api api = _Api();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'advanced filters are independent of text search and cancellable',
    (tester) async {
      final session = _Session();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PanelScope(session: session, child: child!),
          home: const Scaffold(body: LogsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(session.api.queries.single, {'source': 'panel', 'lines': '200'});

      await tester.enterText(find.byType(TextField), 'login');
      await tester.pumpAndSettle();
      await tester.tap(find.text('高级筛选 · 1'));
      await tester.pumpAndSettle();
      expect(find.text('日志类型'), findsOneWidget);
      expect(find.text('时间范围'), findsOneWidget);
      expect(find.text('读取行数'), findsOneWidget);
      await tester.tap(find.text('信息'));
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('高级筛选 · 1'), findsOneWidget);
      expect(session.api.queries.length, 1);

      await tester.tap(find.text('高级筛选 · 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('信息'));
      await tester.tap(find.text('200 行'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('500 行').last);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '应用'));
      await tester.pumpAndSettle();
      expect(session.api.queries.last, {'source': 'panel', 'lines': '500'});
      expect(find.text('高级筛选 · 2'), findsOneWidget);
      expect(find.text('筛选内容'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'login',
      );
      final rows = tester
          .widgetList<SelectableText>(find.byType(SelectableText))
          .map((row) => row.textSpan?.toPlainText() ?? row.data ?? '')
          .toList();
      expect(rows.where((row) => row.contains('failed login')), hasLength(1));
      expect(rows.where((row) => row.contains('login ready')), isEmpty);
    },
  );

  testWidgets('mobile source button label is at most five Chinese characters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = _Session();
    addTearDown(session.dispose);
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => PanelScope(session: session, child: child!),
        home: const Scaffold(body: LogsPage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('面板运行日'), findsOneWidget);
    expect(find.text('面板运行日志记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
