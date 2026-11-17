import 'package:material_ui/material_ui.dart';

import '../../core/enrollment.dart';
import '../../core/format.dart';
import '../../core/host_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'login_page.dart';

/// Startup screen for existing installations: lists every saved server and
/// lets the operator pick one. Disconnecting never removes these records.
class ServerPickerPage extends StatefulWidget {
  const ServerPickerPage({
    super.key,
    required this.store,
    required this.activeId,
    required this.onConnect,
    required this.onEnrolled,
    required this.onDelete,
  });

  final HostStore store;
  final String? activeId;
  final Future<void> Function(HostRecord host) onConnect;
  final Future<void> Function(Enrollment enrollment, {String? alias})
  onEnrolled;
  final void Function(HostRecord host) onDelete;

  @override
  State<ServerPickerPage> createState() => _ServerPickerPageState();
}

class _ServerPickerPageState extends State<ServerPickerPage> {
  String? _connectingId;

  Future<void> _connect(HostRecord host) async {
    if (_connectingId != null) return;
    setState(() => _connectingId = host.id);
    try {
      await widget.onConnect(host);
    } finally {
      if (mounted) setState(() => _connectingId = null);
    }
  }

  Future<void> _delete(HostRecord host) async {
    final ok = await confirmDialog(
      context,
      title: '删除服务器',
      message:
          '从本机删除 ${host.alias}（${host.enrollment.endpoint}）？注册凭据会一并删除，服务器上的数据不受影响。',
      confirmLabel: '删除',
      danger: true,
    );
    if (ok != true || !mounted) return;
    widget.onDelete(host);
    setState(() {});
  }

  Future<void> _addHost() async {
    final navigator = Navigator.of(context);
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => LoginPage(
          onEnrolled: (enrollment, {alias}) async {
            await widget.onEnrolled(enrollment, alias: alias);
            navigator.pop();
          },
        ),
      ),
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    final hosts = widget.store.list();
    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: Halftone(opacity: 0.10, spacing: 16)),
          Positioned(
            right: -170,
            top: -190,
            child: Container(
              width: 480,
              height: 480,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: hampanelAccent.withValues(alpha: 0.05),
                border: Border.all(color: hampanelAccent, width: 3),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: EdgeInsets.symmetric(
                  horizontal: compact ? 12 : 24,
                  vertical: compact ? 20 : 40,
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 860),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _header(compact),
                      const SizedBox(height: 24),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '选择服务器',
                                  style: TextStyle(
                                    fontSize: compact ? 20 : 24,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${hosts.length} 台已保存的服务器 · 点击卡片或“连接”进入面板',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: hampanelMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (!compact) ...[
                            const SizedBox(width: 12),
                            OutlinedButton.icon(
                              onPressed: _addHost,
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加服务器'),
                            ),
                          ],
                        ],
                      ),
                      if (compact) ...[
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: _addHost,
                          icon: const Icon(Icons.add, size: 16),
                          label: const Text('添加服务器'),
                        ),
                      ],
                      const SizedBox(height: 14),
                      for (final host in hosts)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: _hostCard(host, compact),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        '服务器凭据保存在本机数据库中。断开连接只会停止请求，'
                        '不会删除这里的记录；需要移除时可在卡片菜单中选择删除。',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.6,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(bool compact) {
    return Row(
      children: [
        Container(
          width: compact ? 46 : 62,
          height: compact ? 46 : 62,
          padding: const EdgeInsets.all(4),
          decoration: BoxDecoration(
            color: hampanelSurfaceAlt,
            border: Border.all(color: hampanelInk, width: 2),
          ),
          child: Image.asset(
            'assets/branding/hampanel-ham.png',
            filterQuality: FilterQuality.none,
          ),
        ),
        SizedBox(width: compact ? 10 : 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'HAMPANEL',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: compact ? 26 : 36,
                  fontWeight: FontWeight.w900,
                  letterSpacing: compact ? 2 : 4,
                  height: 0.95,
                  color: hampanelInk,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '选择已保存的服务器 / SELECT A SERVER',
                style: mangaKicker.copyWith(color: hampanelMuted),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hostCard(HostRecord host, bool compact) {
    final active = host.id == widget.activeId;
    final busy = _connectingId == host.id;
    final enrollment = host.enrollment;
    final connectButton = FilledButton.icon(
      onPressed: _connectingId == null ? () => _connect(host) : null,
      icon: busy
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.login, size: 16),
      label: Text(busy ? '连接中…' : '连接'),
    );
    final deleteMenu = PopupMenuButton<String>(
      tooltip: '服务器操作',
      enabled: _connectingId == null,
      onSelected: (value) {
        if (value == 'delete') _delete(host);
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'delete', child: Text('删除服务器')),
      ],
    );
    final details = Wrap(
      spacing: 14,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _meta('端点', enrollment.endpoint, mono: true),
        if (enrollment.clientCn.isNotEmpty)
          _meta('客户端 CN', enrollment.clientCn, mono: true),
        if (enrollment.entryPrefix.isNotEmpty)
          _meta('入口前缀', enrollment.entryPrefix, mono: true),
        _meta('添加时间', formatTimestamp(host.createdAt)),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: hampanelSurface,
        border: Border.all(
          color: active ? hampanelAccent : hampanelInk,
          width: 2,
        ),
        boxShadow: mangaShadow,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: _connectingId == null ? () => _connect(host) : null,
          child: Padding(
            padding: EdgeInsets.all(compact ? 12 : 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: hampanelSurfaceAlt,
                        border: Border.all(color: hampanelInk, width: 1.5),
                      ),
                      child: const Icon(Icons.dns_outlined, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            host.alias.isEmpty
                                ? enrollment.endpoint
                                : host.alias,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            enrollment.endpoint,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: monospace.copyWith(
                              fontSize: 11.5,
                              color: hampanelMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (active) ...[
                      const SizedBox(width: 8),
                      StatusPill(text: '上次连接', good: true),
                    ],
                  ],
                ),
                const SizedBox(height: 10),
                details,
                const SizedBox(height: 12),
                Row(
                  children: [
                    connectButton,
                    const SizedBox(width: 6),
                    deleteMenu,
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _meta(String label, String value, {bool mono = false}) {
    return RichText(
      text: TextSpan(
        style: TextStyle(fontSize: 11.5, color: hampanelMuted),
        children: [
          TextSpan(text: '$label '),
          TextSpan(
            text: value,
            style: mono
                ? monospace.copyWith(fontSize: 11, color: hampanelInk)
                : TextStyle(color: hampanelInk),
          ),
        ],
      ),
    );
  }
}
