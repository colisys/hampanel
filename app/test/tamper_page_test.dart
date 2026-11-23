import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/api_client.dart';
import 'package:hampanel/core/session.dart';
import 'package:hampanel/features/security/tamper_page.dart';
import 'package:material_ui/material_ui.dart';
import 'package:hampanel/ui/layout.dart';

class _Api extends Fake implements ApiClient {
  final result = Completer<dynamic>();
  Map<String, dynamic> snapshot = {
    'backend': 'bpf_lsm',
    'capacity': 64,
    'degraded': false,
    'entries': <Map<String, dynamic>>[],
  };
  bool lsmFails = false;
  bool postFails = false;
  bool tooling = false;
  final mutations = <String>[];
  @override
  Future<dynamic> getJson(
    String path, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path == '/api/v1/files') {
      return {
        'entries': [
          {'name': 'sample', 'path': '/sample', 'kind': 'file'},
        ],
      };
    }
    if (path == '/api/v1/security/tamper/lsm') {
      if (lsmFails) {
        throw const ApiException(501, 'tamper_lsm_failed', 'Unsupported');
      }
      return snapshot;
    }
    expect(path, '/api/v1/security/tamper');
    return {'tooling': tooling, 'ebpf_detection': true, 'entries': <dynamic>[]};
  }

  @override
  Future<dynamic> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration? timeout,
  }) async {
    if (path.startsWith('/api/v1/security/tamper/lsm')) {
      expect(body, {'path': '/sample'});
      mutations.add(path);
      if (postFails) {
        throw const ApiException(409, 'tamper_lsm_failed', 'PolicyConflict');
      }
      snapshot = {
        ...snapshot,
        'entries': path.endsWith('/remove')
            ? <dynamic>[]
            : [
                {
                  'path': '/sample',
                  'identity_matches': true,
                  'inode_guarded': true,
                },
              ],
      };
      return snapshot;
    }
    expect(path, '/api/v1/security/tamper/detect');
    expect(body, {'path': '/sample'});
    return result.future;
  }
}

class _Session extends ChangeNotifier implements PanelSession {
  @override
  final _Api api = _Api();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  for (final available in [false, true]) {
    testWidgets('persistent rules, available=$available', (tester) async {
      final session = _Session();
      addTearDown(session.dispose);
      session.api.lsmFails = !available;
      if (!available) session.api.tooling = true;
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PanelScope(session: session, child: child!),
          home: const TamperPage(),
        ),
      );
      await tester.pumpAndSettle();
      final add = find.widgetWithText(TextButton, '添加 LSM 规则');
      await tester.ensureVisible(add);
      await tester.pumpAndSettle();
      if (available) {
        await tester.tap(add);
        await tester.pumpAndSettle();
        await tester.tap(find.text('sample'));
        await tester.pumpAndSettle();
        expect(session.api.mutations, ['/api/v1/security/tamper/lsm']);
        expect(find.text('路径身份匹配 · inode 已防护'), findsOneWidget);
      } else {
        expect(tester.widget<TextButton>(add).onPressed, isNull);
        expect(find.textContaining('Unsupported'), findsOneWidget);
        expect(find.text('选择文件并观察'), findsOneWidget);
        expect(
          tester
              .widget<ActionDock>(find.byType(ActionDock))
              .actions
              .single
              .onPressed,
          isNotNull,
        );
      }
      if (available) {
        final remove = find.byTooltip('移除 eBPF 规则');
        await tester.ensureVisible(remove);
        await tester.tap(remove);
        await tester.pumpAndSettle();
        await tester.tap(find.text('移除'));
        await tester.pumpAndSettle();
        expect(
          session.api.mutations.last,
          '/api/v1/security/tamper/lsm/remove',
        );
        expect(find.text('尚未配置 LSM 规则。'), findsOneWidget);
      } else {
        expect(session.api.mutations, isEmpty);
      }
    });
  }
  testWidgets(
    'degraded snapshot separates path identity from inode guard at capacity',
    (tester) async {
      final session = _Session();
      addTearDown(session.dispose);
      session.api.snapshot = {
        ...session.api.snapshot,
        'degraded': true,
        'entries': List.generate(
          64,
          (i) => {
            'path': '/file$i',
            'identity_matches': i > 1,
            'inode_guarded': i != 1,
          },
        ),
      };
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PanelScope(session: session, child: child!),
          home: const TamperPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('部分失效'), findsOneWidget);
      expect(find.text('路径身份不匹配 · inode 已防护'), findsOneWidget);
      expect(find.text('路径身份不匹配 · inode 未防护'), findsOneWidget);
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '添加 LSM 规则'))
            .onPressed,
        isNull,
      );
    },
  );
  testWidgets('LSM mutation HTTP failure is not reported as success', (
    tester,
  ) async {
    final session = _Session();
    addTearDown(session.dispose);
    session.api.postFails = true;
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => PanelScope(session: session, child: child!),
        home: const TamperPage(),
      ),
    );
    await tester.pumpAndSettle();
    final add = find.text('添加 LSM 规则');
    await tester.ensureVisible(add);
    await tester.tap(add);
    await tester.pumpAndSettle();
    await tester.tap(find.text('sample'));
    await tester.pumpAndSettle();
    expect(find.textContaining('PolicyConflict'), findsOneWidget);
    expect(find.text('尚未配置 LSM 规则。'), findsOneWidget);
  });
  for (final blocking in [false, true]) {
    testWidgets('sample independent of chattr, blocking=$blocking', (
      tester,
    ) async {
      final session = _Session();
      addTearDown(session.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) => PanelScope(session: session, child: child!),
          home: const TamperPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择文件并观察'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('sample'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '观察中…'))
            .onPressed,
        isNull,
      );
      session.api.result.complete({
        'blocking': blocking,
        'write_attempts': 0,
        'mode': 'ebpf_detect',
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('本次观察到 0 次'),
        blocking ? findsNothing : findsOneWidget,
      );
      if (blocking) expect(find.textContaining('未收到完整的监测结果'), findsOneWidget);
    });
  }
}
