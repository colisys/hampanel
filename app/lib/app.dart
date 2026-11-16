import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'core/app_paths.dart';

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
  String? _bootstrapError;
  bool _bootstrapping = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncBrightness();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _bootstrapping = true;
      _bootstrapError = null;
    });
    try {
      await AppPaths.init();
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
        _session = active == null
            ? null
            : PanelSession(active.enrollment, hosts);
        _bootstrapping = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _bootstrapping = false;
        _bootstrapError = error.toString();
      });
    }
  }

  void _syncBrightness() {
    final brightness =
        WidgetsBinding.instance.platformDispatcher.platformBrightness;
    setHampanelBrightness(brightness);
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
        systemNavigationBarColor: hampanelBackground,
        systemNavigationBarIconBrightness: brightness == Brightness.dark
            ? Brightness.light
            : Brightness.dark,
      ),
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
      builder: (context, child) => MediaQuery.withClampedTextScaling(
        minScaleFactor: 0.85,
        maxScaleFactor: 1.25,
        child: child ?? const SizedBox.shrink(),
      ),
      home: _bootstrapError != null
          ? _BootstrapError(
              message: _bootstrapError!,
              directory: AppPaths.configDirectory().path,
              onRetry: _bootstrap,
            )
          : _bootstrapping || _hosts == null
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

class _BootstrapError extends StatelessWidget {
  const _BootstrapError({
    required this.message,
    required this.directory,
    required this.onRetry,
  });

  final String message;
  final String directory;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '本地数据加载失败',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    message,
                    style: TextStyle(fontSize: 12, color: hampanelMuted),
                  ),
                  const SizedBox(height: 8),
                  SelectableText(
                    '配置目录：$directory',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重试'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
