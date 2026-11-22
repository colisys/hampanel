import 'dart:io';

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

  test('local disk source lists directories and files on demand', () async {
    final dir = await Directory.systemTemp.createTemp('picker-local');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/sub').create();
    await File('${dir.path}/note.txt').writeAsString('x');

    final source = LocalDirectorySource(start: dir.path);
    final all = await source.list(dir.path, includeFiles: true);
    expect(
      all.map((entry) => entry.name).toSet(),
      containsAll(<String>['sub', 'note.txt']),
    );

    final dirsOnly = await source.list(dir.path);
    expect(dirsOnly.map((entry) => entry.name), ['sub']);
    expect(source.parentOf('${dir.path}/sub'), dir.path.replaceAll(r'\', '/'));

    // A file can only be confirmed when the caller allows files.
    final fileEntry = RemotePickerEntry(
      name: 'note.txt',
      path: '${dir.path}/note.txt',
      isDirectory: false,
    );
    expect(source.selectableEntry(fileEntry, allowFiles: false), isFalse);
    expect(source.selectableEntry(fileEntry, allowFiles: true), isTrue);
  });

  testWidgets('pathInputDialog shows a browse button for any tree', (
    tester,
  ) async {
    // Real filesystem work inside a widget test must run outside the fake
    // async zone, otherwise the future never completes.
    final dir = await tester.runAsync(
      () => Directory.systemTemp.createTemp('picker-dialog'),
    );
    addTearDown(() => dir!.delete(recursive: true));

    String? result;
    await _open(tester, (context) {
      pathInputDialog(
        context,
        title: '保存',
        label: '本机路径',
        source: LocalDirectorySource(start: dir!.path),
        allowFiles: true,
      ).then((value) => result = value);
    });

    expect(find.byType(RemotePathField), findsOneWidget);
    expect(find.byTooltip('浏览并选择文件'), findsOneWidget);
    // Close the dialog so the pending future resolves and the test can finish.
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
