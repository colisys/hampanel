import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/cron/cron_page.dart';
import 'package:material_ui/material_ui.dart';

class _Api extends Fake implements ApiClient {
  Object? posted;
  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async => {
    'panelJobs': [
      {'group': 'Renew', 'id': 'cert-renew', 'label': 'All'},
      {
        'group': 'Renew',
        'id': 'cert-renew:example.org',
        'label': 'example.org',
      },
      {'group': 'Restart', 'id': 'restart-nginx', 'label': 'Nginx'},
    ],
  };
  @override
  Future<dynamic> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    posted = body;
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
    'switching group resets the target and posts only its catalog ID',
    (tester) async {
      final session = _Session();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PanelScope(session: session, child: child!),
          home: const Scaffold(body: CronPage()),
        ),
      );
      await tester.pumpAndSettle();
      for (final text in [
        '新增任务',
        '面板任务',
        'All',
        'example.org',
        'Renew',
        'Restart',
        '创建',
      ]) {
        final item = find.text(text).last;
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
      }
      expect(session.api.posted, {
        'schedule': '0 3 * * *',
        'kind': 'panel',
        'jobId': 'restart-nginx',
      });
    },
  );
}
