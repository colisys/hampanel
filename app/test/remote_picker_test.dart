import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/ui/remote_picker.dart';
import 'package:material_ui/material_ui.dart';

final _source = TreePickerSource(
  title: '远程选择',
  nodes: const [
    RemotePickerNode(name: 'Volume A', path: 'a'),
    RemotePickerNode(
      name: 'Group',
      path: 'group',
      selectable: false,
      children: [RemotePickerNode(name: 'Volume B', path: 'group/b')],
    ),
  ],
);

Future<void> _open(WidgetTester tester, ValueChanged<BuildContext> open) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('single picker returns a tree leaf as a String', (tester) async {
    String? result;
    await _open(tester, (context) async {
      result = await showRemotePicker(context, source: _source);
    });
    expect(find.text('反选'), findsNothing);
    await tester.tap(find.text('Volume A'));
    await tester.pumpAndSettle();
    expect(result, 'a');
  });

  testWidgets('multi picker keeps selection when navigating', (tester) async {
    List<String>? result;
    await _open(tester, (context) async {
      result = await showRemoteMultiPicker(context, source: _source);
    });
    final confirm = find.widgetWithText(FilledButton, '选择');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(find.byType(Checkbox), findsOneWidget);
    await tester.tap(find.text('全选'));
    await tester.tap(find.text('Group'));
    await tester.pumpAndSettle();
    expect(find.text('选择当前位置'), findsNothing);
    await tester.tap(find.text('反选'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 2 项'), findsOneWidget);
    await tester.tap(find.byTooltip('上一级'));
    await tester.pumpAndSettle();
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(result, ['a', 'group/b']);
  });

  testWidgets('multi picker clears selection and returns null on cancel', (
    tester,
  ) async {
    List<String>? result = ['sentinel'];
    await _open(tester, (context) async {
      result = await showRemoteMultiPicker(context, source: _source);
    });
    await tester.tap(find.text('Volume A'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('清空'));
    await tester.pumpAndSettle();
    expect(find.text('已选择 0 项'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
