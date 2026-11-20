import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/databases/database_dialogs.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets('MongoDB registration submits its default port and admin user', (tester) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          result = await databaseDialog(context, '实例', '保存', ['port', 'user'], instance: true);
        },
        child: const Text('打开'),
      ),
    ))));
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('MySQL').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('MongoDB').last);
    await tester.pumpAndSettle();
    expect(find.text('27017'), findsOneWidget);
    expect(find.text('admin'), findsOneWidget);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(result?['engine'], 'mongo');
    expect(result?['port'], 27017);
    expect(result?['user'], 'admin');
  });

  testWidgets('drop requires the exact database name', (tester) async {
    Map<String, dynamic>? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                result = await databaseDialog(context, '删除数据库', '删除', [
                  'confirm',
                ], confirm: 'orders_live');
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), 'orders');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(find.text('名称不匹配'), findsOneWidget);
    expect(result, isNull);
    await tester.enterText(find.byType(TextFormField), 'orders_live');
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(result, {'confirm': 'orders_live'});
  });
}
