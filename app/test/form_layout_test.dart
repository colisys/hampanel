import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:hampanel/ui/widgets.dart';

Future<void> _pump(WidgetTester tester, double width, Widget child) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Padding(padding: const EdgeInsets.all(12), child: child),
      ),
    ),
  );
}

void main() {
  testWidgets('FormRow gives each field its own line on a phone', (
    tester,
  ) async {
    await _pump(
      tester,
      360,
      FormRow(
        children: const [
          TextField(key: Key('a')),
          TextField(key: Key('b')),
        ],
      ),
    );
    final a = tester.getRect(find.byKey(const Key('a')));
    final b = tester.getRect(find.byKey(const Key('b')));
    expect(a.top, lessThan(b.top));
    expect(a.width, greaterThan(300));
    expect(b.width, greaterThan(300));
  });

  testWidgets('FormRow keeps fields side by side on desktop', (tester) async {
    await _pump(
      tester,
      1200,
      FormRow(
        children: const [
          TextField(key: Key('a')),
          TextField(key: Key('b')),
        ],
      ),
    );
    final a = tester.getRect(find.byKey(const Key('a')));
    final b = tester.getRect(find.byKey(const Key('b')));
    expect(a.top, b.top);
    expect(a.right, lessThan(b.left));
  });

  testWidgets('FieldWithActions stacks buttons under the field on a phone', (
    tester,
  ) async {
    await _pump(
      tester,
      360,
      FieldWithActions(
        field: const TextField(key: Key('field')),
        actions: [
          FilledButton(
            key: const Key('action'),
            onPressed: () {},
            child: const Text('保存'),
          ),
        ],
      ),
    );
    final field = tester.getRect(find.byKey(const Key('field')));
    final action = tester.getRect(find.byKey(const Key('action')));
    expect(field.width, greaterThan(300));
    expect(action.top, greaterThan(field.bottom));
  });
}
