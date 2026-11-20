import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/recycle/recycle_page.dart';
import 'package:hampanel/features/files/files_page.dart';
import 'package:material_ui/material_ui.dart';

class _Session extends ChangeNotifier implements PanelSession {
  _Session(this.api);

  @override
  final ApiClient api;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FilesApi implements ApiClient {
  bool fileExists = true;
  List<String>? deleted;

  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path == '/api/v1/recycle') {
      return {
        'entries': [
          {
            'name': 'long-filename-' * 8,
            'original_path': '/archive/' * 12,
            'size': 100,
          },
        ],
      };
    }
    if (path == '/api/v1/system') return {'platform': 'linux'};
    final directory = query!['path'];
    return {
      'path': directory,
      'entries': directory == '/'
          ? [
              if (fileExists) {'name': 'alpha.txt', 'path': '/alpha.txt'},
              {'name': 'folder', 'path': '/folder', 'kind': 'dir'},
            ]
          : [
              {'name': 'child.txt', 'path': '/folder/child.txt'},
            ],
    };
  }

  @override
  Future<dynamic> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    expect(path, '/api/v1/files/delete');
    deleted = (body as Map)['paths'] as List<String>;
    fileExists = false;
    return {
      'results': [
        {'path': '/alpha.txt', 'ok': true},
        {'path': '/folder', 'ok': false, 'message': '拒绝访问'},
      ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('long recycle entry keeps actions below its path at 320px', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: RecyclePage(api: _FilesApi())));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.text('恢复')).dy,
      greaterThan(tester.getBottomLeft(find.text('/archive/' * 12)).dy),
    );
    await tester.tap(find.byTooltip('永久删除'));
    await tester.pumpAndSettle();
    expect(find.text('该操作不可恢复，会直接删除回收站中的内容。'), findsOneWidget);
  });
  for (final width in [400.0, 1000.0]) {
    testWidgets('batch trash and navigation at width $width', (tester) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _FilesApi();
      final session = _Session(api);
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: PanelScope(
            session: session,
            child: const Scaffold(body: FilesPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.text('反选'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Checkbox>(find.byType(Checkbox).first).value,
        isFalse,
      );
      await tester.tap(find.text('清空'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();
      expect(find.text('已选择 2 项'), findsOneWidget);
      await tester.tap(find.text('移入回收站'));
      await tester.pumpAndSettle();
      expect(api.deleted, isNull);
      await tester.tap(find.widgetWithText(FilledButton, '移入回收站'));
      await tester.pumpAndSettle();
      expect(api.deleted, ['/alpha.txt', '/folder']);
      expect(find.text('alpha.txt'), findsNothing);
      expect(find.text('已选择 1 项'), findsOneWidget);
      await tester.tap(find.text('folder'));
      await tester.pumpAndSettle();
      expect(find.text('child.txt'), findsOneWidget);
      expect(find.text('已选择 0 项'), findsOneWidget);
    });
  }
}
