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
    if (path == '/api/v1/security/honeypot') {
      return {
        'qemu': true,
        'kvm': false,
        'web_image_ready': true,
                'ssh_image_ready': true,
        'kernel': '/boot/test',
      };
    }
    if (path == '/api/v1/security/tamper/lsm') {
      return {'backend': 'bpf_lsm', 'capacity': 64, 'entries': [], 'degraded': false};
    }
    if (path == '/api/v1/security/scan') {
      return {'ebpf': true, 'bpftrace_available': false};
    }
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
    ('扫描感知', '扫描感知', 'security/scan'),
    ('防火墙', '防火墙', 'firewall'),
    ('文件防篡改', '文件防篡改', 'security/tamper'),
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
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text(entry));
      await tester.pumpAndSettle();
      await tester.tap(find.text(entry));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(session.api.reads, contains('/api/v1/$endpoint'));
      expect(find.text(header), findsOneWidget);
      if (endpoint == 'security/scan') {
        expect(find.text('安装探针'), findsNothing);
        expect(find.text('不可用'), findsOneWidget);
      }
      if (endpoint == 'ssh' || endpoint == 'waf') {
        final mode = endpoint == 'ssh' ? 'SSH' : 'Web';
        await tester.tap(find.byTooltip('$mode 蜜罐管理'));
        await tester.pumpAndSettle();
        expect(find.text('SSH / Web 蜜罐'), findsOneWidget);
        expect(
          tester
              .widget<DropdownButton<String>>(
                find.byType(DropdownButton<String>),
              )
              .value,
          endpoint == 'ssh' ? 'ssh' : 'web',
        );
        expect(find.text('就绪'), findsOneWidget);
        expect(session.api.reads.last, '/api/v1/security/honeypot');
        await tester.drag(find.byType(ListView).last, const Offset(0, -400));
        await tester.pumpAndSettle();
        await tester.tap(find.text('启动蜜罐'));
        await tester.pumpAndSettle();
        expect(find.text('确认公开并启动'), findsOneWidget);
        expect(find.textContaining('所有 IPv4 接口'), findsOneWidget);
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
      }
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('安全中心'), findsOneWidget);
    });
  }
}
