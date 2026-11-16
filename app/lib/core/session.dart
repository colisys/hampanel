import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/format.dart';
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

  /// Compares the certificates the daemon reports with the fingerprints in
  /// the enrollment bundle. TLS already validates the chain and hostname;
  /// this detects a rotated or substituted server certificate as well.
  Future<String?> verifyIdentity() async {
    Object? response;
    try {
      response = await api.getJson(
        '/api/v1/health',
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {
      // Unreachable servers surface through the normal page errors; do not
      // turn a network outage into a false identity warning.
      return null;
    }
    if (response is! Map<String, dynamic>) return null;
    final problems = <String>[];
    void check(String label, String expected, Object? actual) {
      final want = normalizeFingerprint(expected);
      final got = normalizeFingerprint(actual is String ? actual : '');
      if (want.isEmpty || got.isEmpty || want == got) return;
      problems.add(
        '$label 不一致\n'
        '注册凭据：${formatFingerprint(want)}\n'
        '服务端实际：${formatFingerprint(got)}',
      );
    }

    check('CA 证书', enrollment.caSha256, response['ca_sha256']);
    check('服务端证书', enrollment.serverSha256, response['server_sha256']);
    if (problems.isEmpty) return null;
    return '服务端身份校验失败\n\n${problems.join('\n\n')}\n\n'
        '可能是服务端轮换了证书，或注册凭据被替换。请通过带外渠道核对新指纹后重新导入注册凭据。';
  }

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
