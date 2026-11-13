import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/enrollment.dart';

class PanelSession extends ChangeNotifier {
  PanelSession(this.enrollment) : api = ApiClient(enrollment);

  final Enrollment enrollment;
  final ApiClient api;

  @override
  void dispose() {
    api.close();
    super.dispose();
  }
}

class PanelScope extends InheritedNotifier<PanelSession> {
  const PanelScope({
    super.key,
    required PanelSession session,
    required super.child,
  }) : super(notifier: session);

  static PanelSession of(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<PanelScope>();
    assert(scope != null, 'PanelScope not found');
    return scope!.notifier!;
  }
}
