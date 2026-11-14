import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/enrollment.dart';
import '../core/host_store.dart';

class PanelSession extends ChangeNotifier {
  PanelSession(this.enrollment, this.hosts) : api = ApiClient(enrollment);

  final Enrollment enrollment;
  final HostStore hosts;
  final ApiClient api;

  /// Rebuilds widgets that read the host list (sidebar switcher, hosts page)
  /// after a CRUD change that does not replace the active session.
  void refreshHosts() => notifyListeners();

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
