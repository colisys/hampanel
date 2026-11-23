import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/store/docker_apps_tab.dart';
import 'package:material_ui/material_ui.dart';

class _StoreApi implements ApiClient {
  _StoreApi({this.deployment});

  final Map<String, dynamic>? deployment;
  int reads = 0;

  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    expect(path, '/api/v1/store/apps');
    reads++;
    return {
      'apps': deployment != null
          ? [deployment]
          : [
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
  for (final (running, legacy, label) in [
    (true, true, '运行中'),
    (true, false, '运行中'),
    (false, false, '已停止'),
    (null, null, '状态未知'),
  ]) {
    testWidgets('nginx deployment: $label, legacy=$legacy', (tester) async {
      final api = _StoreApi(
        deployment: {
          'slug': 'nginx',
          'name': 'Nginx',
          'installed': true,
          'running': ?running,
          'legacy_upgrade_available': ?legacy,
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: PanelScope(
            session: _Session(api),
            child: const Scaffold(body: DockerAppsTab()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(label), findsOneWidget);
      expect(find.text('启动'), running == false ? findsOneWidget : findsNothing);
      expect(find.text('停止'), running == true ? findsOneWidget : findsNothing);
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      expect(
        find.text('升级旧版部署（保留端口）'),
        legacy == true ? findsOneWidget : findsNothing,
      );
    });
  }
  testWidgets('refresh status fetches the current deployment state', (
    tester,
  ) async {
    final deployment = <String, dynamic>{
      'slug': 'nginx',
      'name': 'Nginx',
      'installed': true,
      'running': false,
      'legacy_upgrade_available': true,
    };
    final api = _StoreApi(deployment: deployment);
    await tester.pumpWidget(
      MaterialApp(
        home: PanelScope(
          session: _Session(api),
          child: const Scaffold(body: DockerAppsTab()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已停止'), findsOneWidget);
    deployment['running'] = true;
    deployment['legacy_upgrade_available'] = false;
    await tester.tap(find.text('刷新状态'));
    await tester.pumpAndSettle();
    expect(api.reads, 2);
    expect(find.text('运行中'), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    expect(find.text('升级旧版部署（保留端口）'), findsNothing);
  });

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
