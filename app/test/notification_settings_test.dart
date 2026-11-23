import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/features/settings/notification_settings.dart';

class _Api extends Fake implements ApiClient {
  final config = <String, dynamic>{
    'bark_enabled': true,
    'bark_server': 'https://api.day.app',
    'bark_key': 'test',
    'ntfy_enabled': false,
    'ntfy_token': 'unchanged',
    'memory_percent': 90,
    'disk_percent': 90,
    'cooldown_minutes': 30,
    for (final event in [
      'login',
      'ai_command',
      'service_restart',
      'docker_restart',
      'availability',
    ])
      'event_$event': true,
  };
  Map<String, dynamic>? saved;
  Object? tested;

  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    expect(path, '/api/v1/notifications');
    return config;
  }

  @override
  Future<dynamic> putJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    expect(path, '/api/v1/notifications');
    saved = Map<String, dynamic>.from(body! as Map);
    return saved;
  }

  @override
  Future<dynamic> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    expect(path, '/api/v1/notifications/test');
    tested = body;
    return {'ok': false};
  }
}

void main() {
  testWidgets('provider drafts are validated, saved and tested independently', (
    tester,
  ) async {
    final api = _Api();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: NotificationSettings(api: api)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> enter(String key, String value) async {
      final field = find.byKey(ValueKey(key));
      await tester.ensureVisible(field);
      await tester.enterText(field, value);
      await tester.pump();
    }

    Future<void> click(String label) async {
      final button = find.text(label);
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
    }

    await enter('bark_key', 'invalid!');
    await enter('ntfy_token', 'new-token');
    await click('保存ntfy');
    expect(api.saved, {...api.config, 'ntfy_token': 'new-token'});
    await click('保存Bark');
    expect(find.textContaining('128 位'), findsOneWidget);
    await enter('bark_key', 'new-key');
    await enter('ntfy_token', 'second-draft');
    await click('保存Bark');
    expect(api.saved, {
      ...api.config,
      'ntfy_token': 'new-token',
      'bark_key': 'new-key',
    });
    await click('测试 Bark');
    expect(api.tested, {'provider': 'bark'});
    await click('保存ntfy');
    expect(api.saved?['ntfy_token'], 'second-draft');
  });
  testWidgets(
    'validates thresholds, saves full config, then tests saved provider',
    (tester) async {
      final api = _Api();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: NotificationSettings(api: api)),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final threshold = find.byKey(const ValueKey('disk_percent'));
      final save = find.text('保存资源告警');
      for (final value in ['101', '75']) {
        await tester.ensureVisible(threshold);
        await tester.enterText(threshold, value);
        await tester.pump();
        final test = tester.widget<OutlinedButton>(
          find.widgetWithText(OutlinedButton, '测试 Bark'),
        );
        expect(test.onPressed, isNotNull);
        await tester.ensureVisible(save);
        await tester.tap(save);
        await tester.pumpAndSettle();
        if (value == '101') expect(api.saved, isNull);
      }
      expect(api.saved, {...api.config, 'disk_percent': 75});
      final send = find.text('测试 Bark');
      await tester.ensureVisible(send);
      await tester.tap(send);
      await tester.pumpAndSettle();
      expect(api.tested, {'provider': 'bark'});
      expect(
        find.descendant(
          of: find.byType(SnackBar),
          matching: find.text('发送失败，请检查推送服务配置。'),
        ),
        findsOneWidget,
      );
    },
  );
}
