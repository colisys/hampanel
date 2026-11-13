import 'package:material_ui/material_ui.dart';

import 'core/enrollment.dart';
import 'features/auth/login_page.dart';
import 'features/shell/panel_shell.dart';
import 'core/session.dart';
import 'ui/theme.dart';

class HampanelApp extends StatefulWidget {
  const HampanelApp({super.key, this.initial});

  final Enrollment? initial;

  @override
  State<HampanelApp> createState() => _HampanelAppState();
}

class _HampanelAppState extends State<HampanelApp> {
  PanelSession? _session;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    if (initial != null) _session = PanelSession(initial);
  }

  Future<void> _onEnrolled(Enrollment enrollment) async {
    await enrollment.save();
    _session?.dispose();
    setState(() => _session = PanelSession(enrollment));
  }

  Future<void> _logout() async {
    await Enrollment.clear();
    _session?.dispose();
    setState(() => _session = null);
  }

  @override
  void dispose() {
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    return MaterialApp(
      title: 'Hampanel',
      debugShowCheckedModeBanner: false,
      theme: buildHampanelTheme(),
      home: session == null
          ? LoginPage(onEnrolled: _onEnrolled)
          : PanelScope(
              session: session,
              child: PanelShell(onLogout: _logout),
            ),
    );
  }
}
