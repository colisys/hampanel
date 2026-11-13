import 'package:material_ui/material_ui.dart';

import '../../core/build_info.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../ai/ai_page.dart';
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
  final WidgetBuilder builder;
}

class PanelShell extends StatefulWidget {
  const PanelShell({super.key, required this.onLogout});

  final Future<void> Function() onLogout;

  @override
  State<PanelShell> createState() => _PanelShellState();
}

class _PanelShellState extends State<PanelShell> {
  int _index = 0;

  static final _destinations = <_Destination>[
    _Destination(
      '概览',
      Icons.space_dashboard_outlined,
      (_) => const DashboardPage(),
    ),
    _Destination('AI 助手', Icons.auto_awesome_outlined, (_) => const AiPage()),
    _Destination('进程', Icons.memory_outlined, (_) => const ProcessesPage()),
    _Destination('文件', Icons.folder_open_outlined, (_) => const FilesPage()),
    _Destination('回收站', Icons.delete_outline, (_) => const RecyclePage()),
    _Destination('终端', Icons.terminal_outlined, (_) => const TerminalPage()),
    _Destination('端口穿透', Icons.swap_horiz, (_) => const TunnelsPage()),
    _Destination(
      '服务',
      Icons.settings_suggest_outlined,
      (_) => const ServicesPage(),
    ),
    _Destination('网站', Icons.public_outlined, (_) => const SitesPage()),
    _Destination('容器', Icons.widgets_outlined, (_) => const DockerPage()),
    _Destination('应用商店', Icons.storefront_outlined, (_) => const StorePage()),
    _Destination('运行环境', Icons.hub_outlined, (_) => const RuntimesPage()),
    _Destination('软件', Icons.inventory_2_outlined, (_) => const SoftwarePage()),
    _Destination('SSH', Icons.vpn_key_outlined, (_) => const SshPage()),
    _Destination('WAF', Icons.security_outlined, (_) => const WafPage()),
    _Destination('防火墙', Icons.shield_outlined, (_) => const FirewallPage()),
    _Destination('计划任务', Icons.schedule_outlined, (_) => const CronPage()),
    _Destination('日志', Icons.receipt_long_outlined, (_) => const LogsPage()),
    _Destination('设置', Icons.tune_outlined, (_) => const SettingsPage()),
  ];

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
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 16),
                  child: Row(
                    children: [
                      Container(
                        width: 32,
                        height: 32,
                        color: hampanelInk,
                        child: Icon(
                          Icons.dns_outlined,
                          color: hampanelSurface,
                          size: 19,
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
                const Divider(),
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
                            onTap: () => setState(() => _index = index),
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
                const Divider(),
                Container(
                  decoration: BoxDecoration(
                    border: Border(top: BorderSide(color: hampanelInk, width: 2)),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lock,
                            size: 13,
                            color: hampanelAccent,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              session.enrollment.endpoint,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 10.5,
                                color: hampanelMuted,
                              ),
                            ),
                          ),
                        ],
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
                      Text(
                        _destinations[_index].label,
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
                  child: IndexedStack(
                    index: _index,
                    children: [
                      for (final destination in _destinations)
                        destination.builder(context),
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
