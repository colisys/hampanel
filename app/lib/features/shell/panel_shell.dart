import 'package:material_ui/material_ui.dart';

import '../../core/build_info.dart';
import '../../core/host_store.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../ai/ai_page.dart';
import '../hosts/hosts_page.dart';
import '../cron/cron_page.dart';
import '../dashboard/dashboard_page.dart';
import '../docker/docker_page.dart';
import '../files/files_page.dart';
import '../firewall/firewall_page.dart';
import '../logs/logs_page.dart';
import '../processes/processes_page.dart';
import '../recycle/recycle_page.dart';
import '../services/services_page.dart';
import '../settings/settings_page.dart';
import '../sites/sites_page.dart';
import '../software/software_page.dart';
import '../ssh/ssh_page.dart';
import '../store/store_page.dart';
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

class _PanelShellState extends State<PanelShell> {
  int _index = 0;

  List<_Destination> get _destinations => [
    _Destination(
      '概览',
      Icons.space_dashboard_outlined,
      (_, _) => const DashboardPage(),
    ),
    _Destination(
      'AI 助手',
      Icons.auto_awesome_outlined,
      (_, active) => AiPage(active: active),
    ),
    _Destination('进程', Icons.memory_outlined, (_, _) => const ProcessesPage()),
    _Destination('文件', Icons.folder_open_outlined, (_, _) => const FilesPage()),
    _Destination('回收站', Icons.delete_outline, (_, _) => const RecyclePage()),
    _Destination(
      '终端',
      Icons.terminal_outlined,
      (_, active) => TerminalPage(autoConnect: active),
    ),
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
    _Destination('网站', Icons.public_outlined, (_, _) => const SitesPage()),
    _Destination('容器', Icons.widgets_outlined, (_, _) => const DockerPage()),
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

  @override
  Widget build(BuildContext context) {
    final session = PanelScope.of(context);
    return Scaffold(
      body: Row(
        children: [
          Container(
            width: 230,
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
                          width: 30,
                          height: 30,
                          color: hampanelInk,
                          child: Icon(
                            Icons.dns_outlined,
                            color: hampanelSurface,
                            size: 18,
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
                            onTap: () => setState(() {
                              _index = index;
                              _hostsOpen = false;
                            }),
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
                    border: Border(
                      top: BorderSide(color: hampanelInk, width: 2),
                    ),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _HostSwitcher(
                        session: session,
                        onSwitchHost: widget.onSwitchHost,
                        onManage: () => setState(() => _hostsOpen = true),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: OutlinedButton.icon(
                          onPressed: widget.onLogout,
                          icon: const Icon(Icons.logout, size: 15),
                          label: const Text(
                            '断开连接',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: Column(
              children: [
                Container(
                  height: 56,
                  decoration: BoxDecoration(
                    color: hampanelBackground,
                    border: Border(
                      bottom: BorderSide(color: hampanelInk, width: 2),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      if (_hostsOpen) ...[
                        IconButton(
                          tooltip: '返回',
                          onPressed: () => setState(() => _hostsOpen = false),
                          icon: const Icon(Icons.arrow_back, size: 18),
                        ),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        _hostsOpen ? '主机管理' : _destinations[_index].label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(color: hampanelInk, width: 1.5),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.verified_user_outlined,
                              size: 12,
                              color: hampanelAccent,
                            ),
                            SizedBox(width: 6),
                            Text(
                              'mTLS 已加密',
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10,
                                color: hampanelInk,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: _hostsOpen
                      ? HostsPage(
                          key: ValueKey('hosts-${widget.sessionKey}'),
                          onSwitchHost: widget.onSwitchHost,
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
