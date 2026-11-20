import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/ui/code_editor.dart';
import 'package:material_ui/material_ui.dart';
import 'package:re_editor/re_editor.dart' as re;

void main() {
  for (final readOnly in [false, true]) {
    testWidgets('switching syntax preserves editor state (readOnly: $readOnly)', (
      tester,
    ) async {
      String? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CodeEditorPane(
              initialText: 'answer: 42',
              language: CodeLanguage.yaml,
              readOnly: readOnly,
              onSave: (text) => saved = text,
            ),
          ),
        ),
      );
      re.CodeEditor editor() => tester.widget(find.byType(re.CodeEditor));
      final controller = editor().controller!;
      if (!readOnly) controller.text = '{"answer": 43}';
      controller.selectAll();
      final selection = controller.selection;
      final text = controller.text;
      final findController = editor().findController;
      expect(editor().style!.codeTheme!.languages.keys, ['yaml']);

      Future<void> openSyntaxMenu() async {
        await tester.tap(find.byTooltip('语法高亮'));
        await tester.pumpAndSettle();
      }

      await openSyntaxMenu();
      for (final language in CodeLanguage.values) {
        expect(find.text(language.label), findsOneWidget);
      }
      await tester.tap(find.text('JSON'));
      await tester.pumpAndSettle();
      expect(editor().style!.codeTheme!.languages.keys, ['json']);
      expect(editor().readOnly, readOnly);
      expect(editor().controller, same(controller));
      expect(editor().findController, same(findController));
      expect(controller.text, text);
      expect(controller.selection, selection);

      await openSyntaxMenu();
      await tester.tap(find.text('文本'));
      await tester.pumpAndSettle();
      expect(editor().style!.codeTheme, isNull);

      await openSyntaxMenu();
      await tester.tap(find.text('自动 · YAML'));
      await tester.pumpAndSettle();
      expect(editor().style!.codeTheme!.languages.keys, ['yaml']);
      expect(controller.selection, selection);
      if (readOnly) {
        expect(find.text('保存'), findsNothing);
      } else {
        await tester.tap(find.text('保存'));
        expect(saved, text);
      }
    });
  }
}
