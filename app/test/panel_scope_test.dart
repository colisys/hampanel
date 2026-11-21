import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Regression guard for the security-center crash.
///
/// A route pushed with Navigator is a sibling of `MaterialApp.home`, not a
/// descendant of it. PanelScope used to live inside `home`, so every pushed
/// page that called `PanelScope.of(context)` — all seven security pages did —
/// threw "Null check operator used on a null value". It now sits in
/// `MaterialApp.builder`, above the Navigator.
///
/// The assertion is about placement, which is what broke, so it uses a plain
/// InheritedNotifier with the same shape: a scope installed in `builder` must
/// be visible from a pushed route.
class _Scope extends InheritedNotifier<ChangeNotifier> {
  const _Scope({required ChangeNotifier notifier, required super.child})
    : super(notifier: notifier);
}

class _Probe extends StatelessWidget {
  const _Probe();

  @override
  Widget build(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_Scope>();
    return Scaffold(body: Text('found ${scope != null}'));
  }
}

void main() {
  testWidgets('a scope installed in MaterialApp.builder reaches pushed routes', (
    tester,
  ) async {
    final notifier = ChangeNotifier();
    addTearDown(notifier.dispose);

    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            _Scope(notifier: notifier, child: child ?? const SizedBox.shrink()),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => const _Probe()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('found true'), findsOneWidget);
  });
}
