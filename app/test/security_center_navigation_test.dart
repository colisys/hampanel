import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/security/security_center_page.dart';
import 'package:material_ui/material_ui.dart';

class _Api extends Fake implements ApiClient {
  final reads = <String>[];

  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    reads.add(path);
    if (path == '/api/v1/software') {
      return {
        'items': [
          {'id': 'fail2ban', 'name': 'Fail2ban', 'initialized': true},
        ],
      };
    }
    return <String, dynamic>{};
  }
}

class _Session extends ChangeNotifier implements PanelSession {
  @override
  final _Api api = _Api();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final (entry, header, endpoint) in [
    ('SSH 访问', 'SSH 管理', 'ssh'),
    ('WAF 边缘', 'WAF', 'waf'),
    ('防火墙', '防火墙', 'firewall'),
    ('Fail2ban 封禁', '封禁管理', 'fail2ban'),
  ]) {
    testWidgets('$entry opens a standalone route and returns to the hub', (
      tester,
    ) async {
      final session = _Session();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PanelScope(session: session, child: child!),
          home: const Scaffold(body: SecurityCenterPage()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(find.text(entry), 240);
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(session.api.reads, contains('/api/v1/$endpoint'));
      expect(find.text(header), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('安全中心'), findsOneWidget);
    });
  }
}
