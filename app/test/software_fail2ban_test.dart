import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/software/software_page.dart';
import 'package:material_ui/material_ui.dart';

class _Api extends Fake implements ApiClient {
  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path == '/api/v1/software') {
      return {
        'items': [
          {'id': 'fail2ban', 'name': 'Fail2ban', 'installed': true, 'initialized': true},
        ],
      };
    }
    if (path == '/api/v1/fail2ban') {
      return {
        'installed': true,
        'initialized': true,
        'active': true,
        'jails': [
          {'name': 'sshd', 'banned_ips': ['192.0.2.1']},
          {'name': 'nginx', 'banned_ips': ['192.0.2.2']},
        ],
      };
    }
    throw StateError('Unexpected path: $path');
  }
}

class _Session extends ChangeNotifier implements PanelSession {
  @override
  final ApiClient api = _Api();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('jails are separated and view-all uses an outlined button', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final session = _Session();
    addTearDown(session.dispose);
    await tester.pumpWidget(MaterialApp(
      home: PanelScope(
        session: session,
        child: const Scaffold(body: SoftwarePage()),
      ),
    ));
    await tester.pumpAndSettle();
    final viewAll = find.widgetWithText(OutlinedButton, '查看全部 1 个封禁 IP');
    expect(viewAll, findsNWidgets(2));
    final firstButton = tester.getTopLeft(viewAll.first);
    final secondButton = tester.getTopLeft(viewAll.last);
    expect(secondButton.dy - firstButton.dy, greaterThan(40));
    await tester.tap(viewAll.first);
    await tester.pumpAndSettle();
    expect(find.text('sshd 封禁 IP'), findsOneWidget);
  });
}
