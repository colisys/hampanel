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

class _HampanelAppState extends State<HampanelApp>
    with WidgetsBindingObserver {
  PanelSession? _session;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncBrightness();
    final initial = widget.initial;
    if (initial != null) _session = PanelSession(initial);
  }

  void _syncBrightness() {
    setHampanelBrightness(
      WidgetsBinding.instance.platformDispatcher.platformBrightness,
    );
  }

  @override
  void didChangePlatformBrightness() {
    setState(_syncBrightness);
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
    WidgetsBinding.instance.removeObserver(this);
    _session?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = _session;
    _syncBrightness();
    return MaterialApp(
      key: ValueKey(hampanelBrightness),
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
