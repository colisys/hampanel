import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/store/docker_apps_tab.dart';
import 'package:material_ui/material_ui.dart';

class _StoreApi implements ApiClient {
  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    expect(path, '/api/v1/store/apps');
    return {
      'apps': [
        {
          'slug': 'emqx',
          'name': 'EMQX',
          'description': 'MQTT broker',
          'category': '消息队列',
          'icon': 'database',
          'installed': false,
          'params': [],
        },
        {
          'slug': 'caddy',
          'name': 'Caddy',
          'description': 'Web server',
          'category': 'Web',
          'icon': 'web',
          'installed': false,
          'params': [],
        },
      ],
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session extends ChangeNotifier implements PanelSession {
  _Session(this.api);

  @override
  final ApiClient api;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('store filters by category and search, then clears filters', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelScope(
          session: _Session(_StoreApi()),
          child: const Scaffold(body: DockerAppsTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('EMQX'), findsOneWidget);
    expect(find.text('Caddy'), findsOneWidget);

    await tester.tap(find.widgetWithText(ChoiceChip, '消息队列'));
    await tester.pumpAndSettle();
    expect(find.text('EMQX'), findsOneWidget);
    expect(find.text('Caddy'), findsNothing);

    await tester.enterText(find.byType(TextField).first, 'Caddy');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的应用，清除筛选'), findsOneWidget);
    await tester.tap(find.text('没有匹配的应用，清除筛选'));
    await tester.pumpAndSettle();
    expect(find.text('Caddy'), findsOneWidget);
    expect(find.widgetWithText(ChoiceChip, '全部'), findsOneWidget);
  });
}
