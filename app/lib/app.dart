import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'core/app_paths.dart';

import 'core/enrollment.dart';
import 'core/host_store.dart';
import 'core/session.dart';
import 'features/auth/login_page.dart';
import 'features/auth/server_picker_page.dart';
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
  String? _trustError;
  String? _trustHostId;
  bool _pinMismatch = false;
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
      _trustError = null;
      _pinMismatch = false;
    });
    try {
      await AppPaths.init();
      final hosts = await HostStore.open();
      final initial = widget.initial;
      final host = initial != null
          ? hosts.upsert(alias: null, enrollment: initial, activate: true)
          : hosts.active();
      if (!mounted) return;
      setState(() {
        _hosts = hosts;
        _activeId = host?.id;
        _session = null;
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
    await _activate(host);
  }

  Future<void> _switchHost(HostRecord host) async {
    _hosts?.setActive(host.id);
    await _activate(host);
  }

  Future<void> _activate(HostRecord host) async {
    final hosts = _hosts;
    if (hosts == null) return;
    final pinIssue = hosts.pinMismatch(host);
    if (pinIssue != null) {
      setState(() {
        _activeId = host.id;
        _trustHostId = host.id;
        _session?.dispose();
        _session = null;
        _trustError = pinIssue;
        _pinMismatch = true;
      });
      return;
    }
    final session = PanelSession(host.enrollment, hosts);
    final identityIssue = await session.verifyIdentity();
    if (identityIssue != null) {
      session.dispose();
      if (!mounted) return;
      setState(() {
        _activeId = host.id;
        _trustHostId = host.id;
        _session?.dispose();
        _session = null;
        _trustError = identityIssue;
        _pinMismatch = false;
      });
      return;
    }
    if (!mounted) {
      session.dispose();
      return;
    }
    setState(() {
      _trustError = null;
      _pinMismatch = false;
      _trustHostId = null;
      _activeId = host.id;
      _session?.dispose();
      _session = session;
    });
  }

  void _trustPinnedHost() {
    final hosts = _hosts;
    final id = _trustHostId;
    if (hosts == null || id == null) return;
    final host = hosts.byId(id);
    if (host == null) {
      _bootstrap();
      return;
    }
    hosts.trustPins(id, host.enrollment);
    _activate(host);
  }

  Future<void> _retryTrust() async {
    final hosts = _hosts;
    final id = _trustHostId;
    final host = (hosts != null && id != null) ? hosts.byId(id) : null;
    if (host != null) {
      await _activate(host);
      return;
    }
    _bootstrap();
  }

  void _deleteHost(HostRecord host) {
    _hosts?.delete(host.id);
    if (_activeId == host.id) setState(() => _activeId = null);
  }

  void _reimportEnrollment() {
    _hosts?.setActive(null);
    _session?.dispose();
    setState(() {
      _session = null;
      _trustError = null;
      _pinMismatch = false;
      _trustHostId = null;
      _activeId = null;
    });
  }

  /// Closing the session only stops requests to the target. Saved servers,
  /// the remembered host and its credentials stay untouched.
  Future<void> _logout() async {
    _session?.dispose();
    setState(() {
      _session = null;
      _trustError = null;
      _pinMismatch = false;
      _trustHostId = null;
    });
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
          : _trustError != null
          ? _BootstrapError(
              title: '服务端身份未通过校验',
              message: _trustError!,
              directory: AppPaths.configDirectory().path,
              onRetry: _retryTrust,
              hint: _pinMismatch
                  ? '如果指纹变化来自你自己的证书轮换，请先带外核对，再更新本机指纹。'
                  : 'TLS 链校验之外还要求服务端报告的证书指纹与注册凭据一致。'
                        '请从服务器重新导出 enroll.json 并导入。',
              trustLabel: _pinMismatch ? '更新本机指纹并继续' : null,
              onTrust: _pinMismatch ? _trustPinnedHost : null,
              reimportLabel: _pinMismatch ? null : '重新导入注册凭据',
              onReimport: _pinMismatch ? null : _reimportEnrollment,
            )
          : _bootstrapping || _hosts == null
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : session == null
          ? (_hosts!.list().isEmpty
                ? LoginPage(onEnrolled: _onEnrolled)
                : ServerPickerPage(
                    store: _hosts!,
                    activeId: _activeId,
                    onConnect: _switchHost,
                    onEnrolled: _onEnrolled,
                    onDelete: _deleteHost,
                  ))
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
    this.title = '本地数据加载失败',
    this.hint,
    this.trustLabel,
    this.onTrust,
    this.reimportLabel,
    this.onReimport,
  });

  final String message;
  final String directory;
  final VoidCallback onRetry;
  final String title;
  final String? hint;
  final String? trustLabel;
  final VoidCallback? onTrust;
  final String? reimportLabel;
  final VoidCallback? onReimport;

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
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(
                    message,
                    style: TextStyle(
                      fontSize: 12,
                      color: hampanelMuted,
                      height: 1.6,
                    ),
                  ),
                  if (hint != null) ...[
                    const SizedBox(height: 10),
                    Text(
                      hint!,
                      style: TextStyle(
                        fontSize: 11.5,
                        color: hampanelMuted,
                        height: 1.6,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  SelectableText(
                    '配置目录：$directory',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 10,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: onRetry,
                        icon: const Icon(Icons.refresh, size: 16),
                        label: const Text('重试'),
                      ),
                      if (onTrust != null)
                        OutlinedButton.icon(
                          onPressed: onTrust,
                          icon: const Icon(
                            Icons.verified_user_outlined,
                            size: 16,
                          ),
                          label: Text(trustLabel ?? '信任'),
                        ),
                      if (onReimport != null)
                        OutlinedButton(
                          onPressed: onReimport,
                          child: Text(reimportLabel ?? '重新导入'),
                        ),
                    ],
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
