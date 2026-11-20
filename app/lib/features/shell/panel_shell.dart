import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/build_info.dart';
import '../../core/host_store.dart';
import '../../core/platform_support.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../ai/ai_page.dart';
import '../hosts/hosts_page.dart';
import '../cron/cron_page.dart';
import '../dashboard/dashboard_page.dart';
import '../docker/docker_page.dart';
import '../databases/databases_page.dart';
import '../files/files_page.dart';
import '../firewall/firewall_page.dart';
import '../graphql/graphql_page.dart';
import '../logs/logs_page.dart';
import '../processes/processes_page.dart';
import '../services/services_page.dart';
import '../settings/settings_page.dart';
import '../sites/sites_page.dart';
import '../software/software_page.dart';
import '../ssh/ssh_page.dart';
import '../store/store_page.dart';
import '../tasks/task_list_page.dart';
import '../runtimes/runtimes_page.dart';
import '../terminal/terminal_page.dart';
import '../tunnels/tunnels_page.dart';
import '../waf/waf_page.dart';

class _Destination {
  const _Destination(this.label, this.icon, this.builder);

  final String label;
  final IconData icon;
  final Widget Function(BuildContext context, bool active) builder;
}

class PanelShell extends StatefulWidget {
  const PanelShell({
    super.key,
    required this.sessionKey,
    required this.onLogout,
    required this.onSwitchHost,
  });

  final String sessionKey;
  final Future<void> Function() onLogout;
  final Future<void> Function(HostRecord host) onSwitchHost;

  @override
  State<PanelShell> createState() => _PanelShellState();
}

enum _LinkState { connected, reconnecting, failed }

class _PanelShellState extends State<PanelShell> {
  int _index = 0;
  _LinkState _link = _LinkState.reconnecting;
  Timer? _heartbeat;
  bool _heartbeatInFlight = false;
  int _heartbeatFailures = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _startHeartbeat());
  }

  @override
  void dispose() {
    _heartbeat?.cancel();
    _session?.tasks.stop();
    super.dispose();
  }

  void _startHeartbeat() {
    if (!mounted) return;
    _heartbeat?.cancel();
    _checkLink();
    _heartbeat = Timer.periodic(
      const Duration(seconds: 8),
      (_) => _checkLink(),
    );
  }

  Future<void> _checkLink() async {
    if (_heartbeatInFlight || !mounted) return;
    _heartbeatInFlight = true;
    try {
      await PanelScope.of(context).api
          .getJson('/api/v1/health', timeout: const Duration(seconds: 4));
      if (!mounted) return;
      if (_link != _LinkState.connected || _heartbeatFailures != 0) {
        setState(() {
          _link = _LinkState.connected;
          _heartbeatFailures = 0;
        });
      }
    } catch (_) {
      if (!mounted) return;
      _heartbeatFailures += 1;
      setState(() {
        _link = _heartbeatFailures >= 3
            ? _LinkState.failed
            : _LinkState.reconnecting;
      });
    } finally {
      _heartbeatInFlight = false;
    }
  }

  List<_Destination> get _destinations => [
    _Destination(
      '概览',
      Icons.space_dashboard_outlined,
      (_, _) => const DashboardPage(),
    ),
    _Destination('任务', Icons.task_alt, (_, _) => const TaskListPage()),
    _Destination(
      'AI 助手',
      Icons.auto_awesome_outlined,
      (_, active) => AiPage(active: active),
    ),
    _Destination('进程', Icons.memory_outlined, (_, _) => const ProcessesPage()),
    _Destination('文件', Icons.folder_open_outlined, (_, _) => const FilesPage()),
    _Destination(
      '终端',
      Icons.terminal_outlined,
      (_, active) => TerminalPage(autoConnect: active),
    ),
    if (PlatformSupport.localTunnels)
      _Destination(
        '端口穿透',
        Icons.swap_horiz,
        (_, active) => TunnelsPage(active: active),
      ),
    _Destination(
      '服务',
      Icons.settings_suggest_outlined,
      (_, _) => const ServicesPage(),
    ),
    _Destination(
      '数据库',
      Icons.storage_outlined,
      (_, active) => active ? const DatabasesPage() : const SizedBox.shrink(),
    ),
    _Destination('GraphQL', Icons.code, (_, _) => const GraphqlPage()),
    _Destination('网站', Icons.public_outlined, (_, _) => const SitesPage()),
    _Destination(
      '容器',
      Icons.widgets_outlined,
      (_, active) => DockerPage(active: active),
    ),
    _Destination(
      '应用商店',
      Icons.storefront_outlined,
      (_, _) => const StorePage(),
    ),
    _Destination('运行环境', Icons.hub_outlined, (_, _) => const RuntimesPage()),
    _Destination(
      '软件',
      Icons.inventory_2_outlined,
      (_, _) => const SoftwarePage(),
    ),
    _Destination('SSH', Icons.vpn_key_outlined, (_, _) => const SshPage()),
    _Destination('WAF', Icons.security_outlined, (_, _) => const WafPage()),
    _Destination('防火墙', Icons.shield_outlined, (_, _) => const FirewallPage()),
    _Destination('计划任务', Icons.schedule_outlined, (_, _) => const CronPage()),
    _Destination('日志', Icons.receipt_long_outlined, (_, _) => const LogsPage()),
    _Destination('设置', Icons.tune_outlined, (_, _) => const SettingsPage()),
  ];

  bool _hostsOpen = false;
  bool _tasksStarted = false;
  PanelSession? _session;

  final _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _session ??= PanelScope.of(context);
    if (!_tasksStarted) {
      _tasksStarted = true;
      _session!.tasks.start();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = PanelScope.of(context);
    final compact = MediaQuery.sizeOf(context).width < 900;
    return PopScope(
      canPop: !_hostsOpen,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _hostsOpen) {
          setState(() => _hostsOpen = false);
        }
      },
      child: Scaffold(
        key: _scaffoldKey,
        drawer: compact
            ? Drawer(
                width: MediaQuery.sizeOf(context).width * 0.82,
                backgroundColor: hampanelSurface,
                child: SafeArea(child: _sidebar(session, drawer: true)),
              )
            : null,
        body: SafeArea(
          child: Row(
            children: [
              if (!compact) _sidebar(session),
              Expanded(
                child: Column(
                  children: [
                    _topBar(compact),
                    Expanded(
                      child: _hostsOpen
                          ? HostsPage(
                              key: ValueKey('hosts-${widget.sessionKey}'),
                              onSwitchHost: _switchHost,
                            )
                          : IndexedStack(
                              key: ValueKey('pages-${widget.sessionKey}'),
                              index: _index,
                              children: [
                                for (final (index, destination)
                                    in _destinations.indexed)
                                  destination.builder(context, index == _index),
                              ],
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sidebar(PanelSession session, {bool drawer = false}) {
    return Container(
      width: drawer ? double.infinity : 230,
      decoration: BoxDecoration(
        color: hampanelSurface,
        border: Border(right: BorderSide(color: hampanelInk, width: 2)),
      ),
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      color: hampanelSurfaceAlt,
                      border: Border.all(color: hampanelInk, width: 1.5),
                    ),
                    child: Image.asset(
                      'assets/branding/hampanel-ham.png',
                      filterQuality: FilterQuality.none,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'HAMPANEL',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.6,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: hampanelInk, width: 1.2),
                    ),
                    child: Text(
                      'v$fullClientVersion',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 9.5,
                        color: hampanelMuted,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 2, thickness: 2),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: _destinations.length,
              itemBuilder: (context, index) {
                final destination = _destinations[index];
                final selected = index == _index;
                return Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  child: Material(
                    color: selected ? hampanelInk : Colors.transparent,
                    borderRadius: BorderRadius.circular(2),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(2),
                      onTap: () => _select(index),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 3,
                              height: 18,
                              color: selected
                                  ? hampanelAccent
                                  : Colors.transparent,
                            ),
                            const SizedBox(width: 9),
                            Icon(
                              destination.icon,
                              size: 18,
                              color: selected
                                  ? hampanelSurface
                                  : hampanelInkSoft,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                destination.label,
                                style: TextStyle(
                                  fontSize: 13,
                                  color: selected
                                      ? hampanelSurface
                                      : hampanelInkSoft,
                                  fontWeight: selected
                                      ? FontWeight.w800
                                      : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: hampanelInk, width: 2)),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _HostSwitcher(
                  session: session,
                  onSwitchHost: _switchHost,
                  onManage: _openHosts,
                ),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _logout,
                    icon: const Icon(Icons.logout, size: 15),
                    label: const Text('断开连接', style: TextStyle(fontSize: 12)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _select(int index) {
    setState(() {
      _index = index;
      _hostsOpen = false;
    });
    _closeDrawer();
  }

  void _openHosts() {
    setState(() => _hostsOpen = true);
    _closeDrawer();
  }

  void _closeDrawer() {
    final scaffold = _scaffoldKey.currentState;
    if (scaffold != null && scaffold.isDrawerOpen) {
      scaffold.closeDrawer();
    }
  }

  Future<void> _logout() async {
    _closeDrawer();
    await widget.onLogout();
  }

  Future<void> _switchHost(HostRecord host) async {
    _closeDrawer();
    await widget.onSwitchHost(host);
  }

  Widget _topBar(bool compact) {
    return Container(
      // 56px header + 2px divider on the sidebar; keep both rules aligned.
      height: 58,
      decoration: BoxDecoration(
        color: hampanelBackground,
        border: Border(bottom: BorderSide(color: hampanelInk, width: 2)),
      ),
      padding: EdgeInsets.symmetric(horizontal: compact ? 6 : 24),
      child: Row(
        children: [
          if (compact)
            IconButton(
              tooltip: '打开菜单',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu, size: 20),
            ),
          if (_hostsOpen)
            IconButton(
              tooltip: '返回',
              onPressed: () => setState(() => _hostsOpen = false),
              icon: const Icon(Icons.arrow_back, size: 18),
            ),
          Expanded(
            child: Text(
              _hostsOpen ? '主机管理' : _destinations[_index].label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
          ),
          Tooltip(
            message: switch (_link) {
              _LinkState.connected => '心跳正常',
              _LinkState.reconnecting => '连接中断，正在重试',
              _LinkState.failed => '连接失败',
            },
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 6 : 8,
                vertical: 4,
              ),
              decoration: BoxDecoration(
                border: Border.all(
                  color: switch (_link) {
                    _LinkState.connected => const Color(0xFF2E7D32),
                    _LinkState.reconnecting => hampanelWarning,
                    _LinkState.failed => hampanelDanger,
                  },
                  width: 1.5,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: switch (_link) {
                        _LinkState.connected => const Color(0xFF2E7D32),
                        _LinkState.reconnecting => hampanelWarning,
                        _LinkState.failed => hampanelDanger,
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    switch (_link) {
                      _LinkState.connected => '已连接',
                      _LinkState.reconnecting => '重连中',
                      _LinkState.failed => '连接失败',
                    },
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 10,
                      color: switch (_link) {
                        _LinkState.connected => const Color(0xFF2E7D32),
                        _LinkState.reconnecting => hampanelWarning,
                        _LinkState.failed => hampanelDanger,
                      },
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HostSwitcher extends StatefulWidget {
  const _HostSwitcher({
    required this.session,
    required this.onSwitchHost,
    required this.onManage,
  });

  final PanelSession session;
  final Future<void> Function(HostRecord host) onSwitchHost;
  final VoidCallback onManage;

  @override
  State<_HostSwitcher> createState() => _HostSwitcherState();
}

class _HostSwitcherState extends State<_HostSwitcher> {
  String? _version;
  String? _versionFor;

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  @override
  void didUpdateWidget(covariant _HostSwitcher oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) _loadVersion();
  }

  Future<void> _loadVersion() async {
    final id = widget.session.hosts.activeId;
    _versionFor = id;
    setState(() => _version = null);
    try {
      final data = await widget.session.api.getJson('/api/v1/health');
      if (!mounted || _versionFor != id) return;
      final version = data is Map ? data['version'] : null;
      setState(() => _version = version is String ? version : null);
    } catch (_) {
      // Version is decorative; connection errors are surfaced elsewhere.
    }
  }

  @override
  Widget build(BuildContext context) {
    final records = widget.session.hosts.list();
    final active = widget.session.hosts.active();
    final alias = active?.alias ?? '未选择主机';
    final endpoint = active?.enrollment.endpoint ?? '-';
    final version = _version == null ? endpoint : '$endpoint · v$_version';
    return PopupMenuButton<String>(
      tooltip: '切换主机',
      position: PopupMenuPosition.over,
      onSelected: (value) {
        if (value == '__manage__') {
          widget.onManage();
          return;
        }
        for (final record in records) {
          if (record.id != value) continue;
          widget.onSwitchHost(record);
        }
      },
      itemBuilder: (context) => [
        for (final record in records)
          PopupMenuItem(
            value: record.id,
            child: Row(
              children: [
                Icon(
                  record.id == active?.id
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 14,
                  color: record.id == active?.id
                      ? hampanelAccent
                      : hampanelMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    record.alias,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  record.enrollment.endpoint,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'monospace',
                    fontSize: 9.5,
                    color: hampanelMuted,
                  ),
                ),
              ],
            ),
          ),
        const PopupMenuDivider(),
        const PopupMenuItem(
          value: '__manage__',
          child: Row(
            children: [
              Icon(Icons.settings_outlined, size: 14),
              SizedBox(width: 8),
              Text('管理主机…', style: TextStyle(fontSize: 12.5)),
            ],
          ),
        ),
      ],
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(color: hampanelInk, width: 1.2),
        ),
        child: Row(
          children: [
            Icon(Icons.lock, size: 13, color: hampanelAccent),
            const SizedBox(width: 6),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    alias,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    version,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 9.5,
                      color: hampanelMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.unfold_more, size: 13, color: hampanelMuted),
          ],
        ),
      ),
    );
  }
}
