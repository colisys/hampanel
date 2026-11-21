import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/security.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'hardening_page.dart';
import 'probe_page.dart';
import '../cron/cron_page.dart';
import '../firewall/firewall_page.dart';
import '../ssh/ssh_page.dart';
import '../waf/waf_page.dart';
import 'honeypot_page.dart';
import 'scan_page.dart';
import 'selinux_page.dart';
import 'tamper_page.dart';

/// Security hub. SSH, WAF and the firewall keep their own pages, but the
/// sidebar now exposes one entry and this page is the index for every
/// security surface, including the new sensors.
class SecurityCenterPage extends StatefulWidget {
  const SecurityCenterPage({super.key});

  @override
  State<SecurityCenterPage> createState() => _SecurityCenterPageState();
}

class _SecurityCenterPageState extends State<SecurityCenterPage> {
  SecurityOverview? _overview;
  SecurityCapabilities? _capabilities;
  bool _loading = true;
  String? _error;
  String? _installing;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        _api.getJson('/api/v1/security/overview'),
        _api.getJson('/api/v1/security/capabilities'),
      ]);
      if (!mounted) return;
      setState(() {
        _overview = SecurityOverview.fromJson(
          results[0] as Map<String, dynamic>? ?? const {},
        );
        _capabilities = SecurityCapabilities.fromJson(
          results[1] as Map<String, dynamic>? ?? const {},
        );
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  void _open(Widget page) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
  }

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    final caps = _capabilities;
    return Column(
      children: [
        PageHeader(
          title: '安全中心',
          subtitle: caps == null
              ? '服务器安全能力与策略'
              : '${caps.root ? 'root 运行' : '非 root 运行'} · '
                    '${[
                      if (caps.ebpf) 'eBPF',
                      if (caps.chattr) 'chattr',
                      if (caps.qemu) 'QEMU',
                    ].join(' · ')}',
          actions: [PageRefreshButton(onPressed: _load, refreshing: _loading)],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : ListView(
                  padding: pageContentPadding(context, top: 8),
                  children: [
                    if (caps != null) _capabilityBanner(caps),
                    const SizedBox(height: 12),
                    _summaryGrid(overview),
                    const SizedBox(height: 16),
                    _sectionTitle('策略与访问控制'),
                    const SizedBox(height: 8),
                    _entry(
                      icon: Icons.vpn_key_outlined,
                      title: 'SSH 访问',
                      subtitle: overview?.ssh == null
                          ? 'sshd 状态、密钥与日志'
                          : '${overview?.ssh?.available == true ? '已安装' : '未检测到'}'
                                ' · '
                                '${overview?.ssh?.running == true ? '运行中' : '未运行'}',
                      onTap: () => _open(const SshPage()),
                    ),
                    _entry(
                      icon: Icons.security_outlined,
                      title: 'WAF 边缘',
                      subtitle: overview?.waf == null
                          ? 'Caddy + Coraza 防护'
                          : '${overview?.waf?.installed == true ? '已构建' : '未构建'}'
                                ' · 模式 ${overview?.waf?.mode ?? '-'}',
                      onTap: () => _open(const WafPage()),
                    ),
                    _entry(
                      icon: Icons.shield_outlined,
                      title: '防火墙',
                      subtitle: overview?.firewall == null
                          ? '主机防火墙规则'
                          : '${overview?.firewall?.available != true ? '不可用' : (overview?.firewall?.active == true ? '已启用' : '未启用')}'
                                ' · ${overview?.firewall?.rules ?? 0} 条规则',
                      onTap: () => _open(const FirewallPage()),
                    ),
                    _entry(
                      icon: Icons.gavel_outlined,
                      title: 'Fail2ban 封禁',
                      subtitle: overview?.fail2ban == null
                          ? '登录爆破封禁'
                          : '${overview?.fail2ban?.initialized == true ? '已托管' : '未托管'}'
                                ' · ${overview?.fail2ban?.jails ?? 0} 个 jail'
                                ' · ${overview?.fail2ban?.banned ?? 0} 个封禁 IP',
                      onTap: () => _open(const CronPage()),
                    ),
                    const SizedBox(height: 16),
                    _sectionTitle('检测与诱捕'),
                    const SizedBox(height: 8),
                    _entry(
                      icon: Icons.radar_outlined,
                      title: '扫描感知',
                      subtitle: caps == null
                          ? 'eBPF 被动采集扫描来源'
                          : caps.ebpf
                          ? 'eBPF 可用 · 自动拉黑命中来源'
                          : 'eBPF 不可用，无法被动采集',
                      enabled: caps?.ebpf ?? false,
                      onTap: () => _open(const ScanPage()),
                    ),
                    _entry(
                      icon: Icons.travel_explore_outlined,
                      title: '主机探测',
                      subtitle: 'nmap 主动扫描与被动情报',
                      onTap: () => _open(const ProbePage()),
                    ),
                    _entry(
                      icon: Icons.hive_outlined,
                      title: 'SSH / Web 蜜罐',
                      subtitle: caps == null
                          ? 'QEMU 嵌套虚拟化诱捕'
                          : caps.qemu
                          ? 'QEMU 可用 · 隔离观察攻击行为'
                          : 'QEMU 不可用',
                      enabled: caps?.qemu ?? false,
                      onTap: () => _open(const HoneypotPage()),
                    ),
                    const SizedBox(height: 16),
                    _sectionTitle('主机加固'),
                    const SizedBox(height: 8),
                    _entry(
                      icon: Icons.build_circle_outlined,
                      title: '主机加固',
                      subtitle: '空链接、umask、at/cron/sudo 与内核参数',
                      onTap: () => _open(const HardeningPage()),
                    ),
                    _entry(
                      icon: Icons.lock_outline,
                      title: '文件防篡改',
                      subtitle: caps == null
                          ? 'chattr 与 eBPF 路径保护'
                          : caps.chattr
                          ? 'chattr 可用 · 关键路径只读保护'
                          : 'chattr 不可用',
                      enabled: caps?.chattr ?? false,
                      onTap: () => _open(const TamperPage()),
                    ),
                    _entry(
                      icon: Icons.policy_outlined,
                      title: 'SELinux',
                      subtitle: caps == null
                          ? '强制访问控制策略'
                          : caps.selinux
                          ? '已启用 SELinux'
                          : '当前主机未启用 SELinux',
                      enabled: caps?.selinux ?? false,
                      onTap: () => _open(const SelinuxPage()),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  /// Security capabilities map onto installable components, so a missing
  /// dependency is a one-click fix instead of a package name the operator has
  /// to look up.
  static const _componentFor = <String, ({String id, String name})>{
    'ebpf': (id: 'bpftrace', name: 'bpftrace'),
    'qemu': (id: 'qemu', name: 'QEMU'),
    'chattr': (id: 'e2fsprogs', name: 'e2fsprogs'),
    'selinux': (id: 'selinux-tools', name: 'SELinux 工具与策略'),
    'auditd': (id: 'auditd', name: 'auditd 审计服务'),
  };

  Future<void> _installComponent(({String id, String name}) component) async {
    setState(() => _installing = component.id);
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'package.install',
        title: '安装 ${component.name}',
        params: {'id': component.id},
      );
      if (!mounted) return;
      showAppSnackBar(context, SnackBar(content: Text('已提交任务：${task.title}')));
      unawaited(center.waitFor(task.id).then((_) {
        if (mounted) _load();
      }));
    } catch (error) {
      showAppSnackBar(context, SnackBar(content: Text(describeError(error))));
    } finally {
      if (mounted) setState(() => _installing = null);
    }
  }

  Widget _capabilityBanner(SecurityCapabilities caps) {
    final missing = <String>[
      if (!caps.ebpf) 'ebpf',
      if (!caps.qemu) 'qemu',
      if (!caps.chattr) 'chattr',
      if (!caps.selinux) 'selinux',
      if (!caps.auditd) 'auditd',
    ];
    if (missing.isEmpty) {
      return PanelCard(
        title: '运行环境',
        child: Text(
          '所有依赖均已就绪，扫描感知与蜜罐可在本机运行。',
          style: TextStyle(fontSize: 11.5, color: hampanelMuted, height: 1.5),
        ),
      );
    }
    final labels = <String, String>{
      'ebpf': 'eBPF（扫描感知）',
      'qemu': 'QEMU（蜜罐）',
      'chattr': 'chattr（防篡改）',
      'selinux': 'SELinux',
      'auditd': 'auditd（SELinux 拒绝日志）',
    };
    return PanelCard(
      title: '运行环境',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            caps.root
                ? '以下能力在当前主机不可用。缺少的工具可直接在此安装：'
                : 'daemon 未以 root 运行，以下能力无法工作（安装也需要 root）：',
            style: TextStyle(fontSize: 11.5, color: hampanelMuted, height: 1.5),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final key in missing)
                if (_componentFor[key] case final component?)
                  InputChip(
                    label: Text(
                      '安装 ${labels[key] ?? component.name}',
                      style: const TextStyle(fontSize: 11),
                    ),
                    avatar: _installing == component.id
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.download_outlined, size: 14),
                    visualDensity: VisualDensity.compact,
                    onPressed: _installing == null || _installing == component.id
                        ? () => _installComponent(component)
                        : null,
                  ),
            ],
          ),
          if (missing.length > 1) ...[
            const SizedBox(height: 10),
            TextButton.icon(
              onPressed: _installing == null
                  ? () async {
                      for (final key in missing) {
                        if (_componentFor[key] case final component?) {
                          await _installComponent(component);
                        }
                      }
                    }
                  : null,
              icon: const Icon(Icons.download_for_offline_outlined, size: 16),
              label: const Text('全部安装', style: TextStyle(fontSize: 12)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summaryGrid(SecurityOverview? overview) {
    final items = <({String label, String value, IconData icon, Color color})>[
      (
        label: '防火墙规则',
        value: '${overview?.firewall?.rules ?? 0}',
        icon: Icons.shield_outlined,
        color: hampanelAccent,
      ),
      (
        label: 'SSH',
        value: overview?.ssh?.running == true ? '运行中' : '未运行',
        icon: Icons.vpn_key_outlined,
        color: overview?.ssh?.running == true ? hampanelAccent : hampanelMuted,
      ),
      (
        label: 'WAF',
        value: overview?.waf?.running == true ? '运行中' : '未运行',
        icon: Icons.security_outlined,
        color: overview?.waf?.running == true ? hampanelAccent : hampanelMuted,
      ),
      (
        label: '封禁 IP',
        value: '${overview?.fail2ban?.banned ?? 0}',
        icon: Icons.gavel_outlined,
        color: (overview?.fail2ban?.banned ?? 0) > 0
            ? hampanelDanger
            : hampanelMuted,
      ),
    ];
    return MetricGrid(
      metrics: [
        for (final item in items)
          MetricCard(
            label: item.label,
            value: item.value,
            icon: item.icon,
            accent: item.color,
          ),
      ],
    );
  }

  Widget _sectionTitle(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: hampanelMuted,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _entry({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: PanelCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: InkWell(
          onTap: enabled ? onTap : null,
          child: Opacity(
            opacity: enabled ? 1 : 0.5,
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 20,
                  color: enabled ? hampanelAccent : hampanelMuted,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: hampanelMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.chevron_right,
                  size: 18,
                  color: enabled ? hampanelMuted : hampanelBorder,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
