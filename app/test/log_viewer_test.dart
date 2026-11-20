import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/ui/log_viewer.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  for (final width in [320.0, 768.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('log toolbar reflows at $width with text scale $scale', (
        tester,
      ) async {
        var advancedOpened = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Builder(
                builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(
                    textScaler: TextScaler.linear(scale),
                  ),
                  child: Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: width,
                      child: LogViewer(
                        content: 'info: ready\nwarning: retry',
                        truncated: true,
                        compactFilters: true,
                        onAdvancedFilter: () => advancedOpened = true,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final field = find.byType(TextField);
        final advanced = find.widgetWithText(OutlinedButton, '高级筛选');
        final copy = find.widgetWithIcon(IconButton, Icons.copy_all_outlined);
        expect(tester.getSize(field).height, tester.getSize(advanced).height);
        expect(tester.getRect(advanced).right, lessThanOrEqualTo(width));
        expect(tester.getRect(copy).right, lessThanOrEqualTo(width));
        if (width == 320) {
          expect(
            tester.getTopLeft(advanced).dy,
            greaterThan(tester.getBottomLeft(field).dy),
          );
        } else {
          expect(tester.getCenter(advanced).dy, tester.getCenter(field).dy);
        }
        await tester.tap(advanced);
        expect(advancedOpened, isTrue);
        await tester.enterText(field, 'missing');
        await tester.pump();
        expect(find.text('高级筛选 · 1'), findsOneWidget);
        expect(find.text('没有匹配的日志行'), findsOneWidget);
        expect(tester.widget<IconButton>(copy).onPressed, isNull);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
