import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/features/software/clamav_panel.dart';

class _Client extends Fake implements ApiClient {
  final response = Completer<dynamic>();

  @override
  Future<dynamic> postJson(String path, Object? body,
      {Map<String, String>? query, Duration? timeout}) async {
    expect(path, '/api/v1/clamav/scan');
    expect(body, {'path': '/srv/sample'});
    return response.future;
  }
}

void main() {
  testWidgets('绝对路径提交到扫描端点并显示检测结果', (tester) async {
    final client = _Client();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: ClamavPanel(client: client))));
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '扫描')).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, '/srv/sample');
    await tester.pump();
    await tester.tap(find.text('扫描'));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '扫描')).onPressed, isNull);
    client.response.complete({'verdict': 'infected', 'exit_code': 1, 'output': 'Fixture FOUND'});
    await tester.pumpAndSettle();
    expect(find.textContaining('Fixture FOUND'), findsOneWidget);
  });
}
