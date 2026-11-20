import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/security.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// SELinux. The host capability is probed first: when the required component is
/// absent this page explains what is missing instead of showing empty controls.
class SelinuxPage extends StatefulWidget {
  const SelinuxPage({super.key});

  @override
  State<SelinuxPage> createState() => _SelinuxPageState();
}

class _SelinuxPageState extends State<SelinuxPage> {
  SecurityCapabilities? _capabilities;
  bool _loading = true;
  String? _error;

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
      final json = await _api.getJson('/api/v1/security/capabilities');
      if (!mounted) return;
      setState(() {
        _capabilities = SecurityCapabilities.fromJson(
          json as Map<String, dynamic>? ?? const {},
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

  bool get _ready {
    final caps = _capabilities;
    if (caps == null) return false;
    return switch ('selinux') {
      'qemu' => caps.qemu,
      'chattr' => caps.chattr,
      'selinux' => caps.selinux,
      _ => false,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ready = _ready;
    return Scaffold(
      appBar: AppBar(
        title: const Text('SELinux'),
        actions: [
          PageRefreshButton(onPressed: _load, refreshing: _loading),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? Padding(
              padding: pageContentPadding(context),
              child: ErrorBanner(message: _error!, onRetry: _load),
            )
          : ListView(
              padding: pageContentPadding(context),
              children: [
                PanelCard(
                  title: '本机状态',
                  trailing: StatusPill(
                    text: ready ? '可配置' : '不可用',
                    good: ready,
                  ),
                  child: Text(
                    '强制访问控制（MAC）策略配置与管理。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: ready ? '说明' : '缺少依赖',
                  child: Text(
                    ready
                        ? '功能入口已就绪，具体策略随对应后端能力开放。'
                        : '当前主机不具备该能力，因此不会展示无法生效的开关。'
                              '依赖可在「设置 → 安全组件」中一键安装。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.6,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
