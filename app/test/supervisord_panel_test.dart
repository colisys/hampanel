import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/software/supervisord_panel.dart';

void main() {
  testWidgets('create passes distinct argv elements', (tester) async {
    final requests = <List<dynamic>>[];
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SupervisordPanel(call: (a,n,s,argv) async {
      requests.add([a,n,argv]);
      return [];
    }))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('创建程序'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'worker');
    await tester.enterText(find.byType(TextField).last, '/bin/sleep\n60');
    await tester.tap(find.text('确认'));
    await tester.pumpAndSettle();
    expect(requests.any((request) => request[0] == 'create' && request[1] == 'worker' &&
      (request[2] as List<String>).join('|') == '/bin/sleep|60'), isTrue);
  });
  testWidgets('renders process identity and requests its stderr', (tester) async {
    final calls = <String>[];
    final response = Completer<String>();
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SupervisordPanel(call: (a,n,s,argv) async {
      calls.add('$a $n $s');
      return a == 'list' ? [{'name':'workers:one','state':'RUNNING','pid':42}] : response.future;
    }))));
    await tester.pumpAndSettle();
    expect(find.text('RUNNING · PID 42'), findsOneWidget);
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('stderr'));
    await tester.pump();
    expect(calls.last, 'logs workers:one stderr');
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    response.complete('diagnostic');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('diagnostic'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });
}
