import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/software/pure_ftpd_controls.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('only valid virtual accounts submit and password is cleared', (t) async {
    final calls = <String>[];
    final response = Completer<void>();
    await t.pumpWidget(MaterialApp(home: Scaffold(body: PureFtpdControls(
      initialized: true, initialize: () async {}, remove: (_) async {},
      add: (name, password) async { calls.add('$name:$password'); await response.future; },
    ))));
    await t.enterText(find.byType(TextField).first, '-bad');
    await t.enterText(find.byType(TextField).last, 'secret');
    await t.pump();
    expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    await t.enterText(find.byType(TextField).first, 'alice');
    await t.pump();
    await t.tap(find.text('创建账号'));
    await t.pump();
    expect(calls, ['alice:secret']);
    expect(t.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull);
    expect(t.widget<TextField>(find.byType(TextField).last).controller!.text, 'secret');
    response.complete();
    await t.pumpAndSettle();
    expect(t.widget<TextField>(find.byType(TextField).last).controller!.text, isEmpty);
  });
}
