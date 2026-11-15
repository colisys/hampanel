import 'package:material_ui/material_ui.dart';

import 'core/enrollment.dart';
import 'core/host_store.dart';
import 'core/session.dart';
import 'features/auth/login_page.dart';
import 'features/shell/panel_shell.dart';
import 'ui/theme.dart';

class HampanelApp extends StatefulWidget {
  const HampanelApp({super.key, this.initial});

  final Enrollment? initial;

  @override
  State<HampanelApp> createState() => _HampanelAppState();
}

class _HampanelAppState extends State<HampanelApp> with WidgetsBindingObserver {
  HostStore? _hosts;
  PanelSession? _session;
  String? _activeId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncBrightness();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final hosts = await HostStore.open();
    final initial = widget.initial;
    HostRecord? active;
    if (initial != null) {
      active = hosts.upsert(alias: null, enrollment: initial, activate: true);
    } else {
      active = hosts.active();
    }
    if (!mounted) return;
    _hosts?.close();
    setState(() {
      _hosts = hosts;
      _activeId = active?.id;
      _session = active == null ? null : PanelSession(active.enrollment, hosts);
    });
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

  Future<void> _onEnrolled(Enrollment enrollment, {String? alias}) async {
    final hosts = _hosts;
    if (hosts == null) return;
    final host = hosts.upsert(
      alias: alias,
      enrollment: enrollment,
      activate: true,
    );
    _applyHost(host);
  }

  Future<void> _switchHost(HostRecord host) async {
    _hosts?.setActive(host.id);
    _applyHost(host);
  }

  void _applyHost(HostRecord host) {
    _session?.dispose();
    setState(() {
      _activeId = host.id;
      _session = PanelSession(host.enrollment, _hosts!);
    });
  }

  Future<void> _logout() async {
    _hosts?.setActive(null);
    _session?.dispose();
    setState(() => _session = null);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _session?.dispose();
    _hosts?.close();
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
      home: _hosts == null
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session == null
          ? LoginPage(onEnrolled: _onEnrolled)
          : PanelScope(
              session: session,
              child: PanelShell(
                key: ValueKey('shell-$_activeId'),
                sessionKey: _activeId!,
                onLogout: _logout,
                onSwitchHost: _switchHost,
              ),
            ),
    );
  }
}
