import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'compose_section.dart';
import 'containers_section.dart';
import 'images_section.dart';
import 'networks_section.dart';
import 'registries_section.dart';
import 'settings_section.dart';
import 'volumes_section.dart';

const _sections = <String>[
  '概览',
  '容器列表',
  '编排管理',
  '镜像管理',
  '网络管理',
  '存储卷',
  '源管理',
  'Docker 设置',
];

class DockerPage extends StatefulWidget {
  const DockerPage({super.key});

  @override
  State<DockerPage> createState() => _DockerPageState();
}

class _DockerPageState extends State<DockerPage> {
  int _selected = 0;
  bool _checking = true;
  bool _engineMissing = false;
  bool _installing = false;
  String? _engine;
  String? _error;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _checkConnection();
  }

  Future<void> _checkConnection() async {
    setState(() {
      _checking = true;
      _error = null;
    });
    try {
      final json = await _api.postJson(
        '/api/v1/docker/test-connection',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _engine = map['engine'] as String?;
        _engineMissing = false;
        _checking = false;
      });
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _engineMissing = error.code == 'engine_unavailable';
        _error = _engineMissing ? null : error.message;
        _checking = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _checking = false;
      });
    }
  }

  Future<void> _installDocker() async {
    setState(() => _installing = true);
    try {
      final json = await _api.postJson(
        '/api/v1/store/packages/docker/install',
        const <String, dynamic>{},
        timeout: const Duration(minutes: 5),
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        _toast(map['output'] as String? ?? 'Docker 安装失败');
      } else {
        _toast('Docker 已安装，正在重新检测');
      }
      await _checkConnection();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const LoadingView();
    }
    if (_engineMissing) {
      return Column(
        children: [
          const PageHeader(title: '容器', subtitle: '未检测到 Docker 或 Podman'),
          Expanded(
            child: EmptyState(
              icon: Icons.widgets_outlined,
              title: '还没有容器运行时',
              message:
                  '容器、运行环境和应用商店的 Docker 应用都依赖 Docker（或兼容的 Podman）。'
                  '可以在应用商店的系统工具里安装 Docker，或直接点击下面的按钮。',
              action: FilledButton.icon(
                onPressed: _installing ? null : _installDocker,
                icon: _installing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 16),
                label: Text(_installing ? '安装中…' : '安装 Docker'),
              ),
            ),
          ),
        ],
      );
    }
    if (_error != null) {
      return Column(
        children: [
          const PageHeader(title: '容器'),
          Expanded(
            child: ErrorBanner(message: _error!, onRetry: _checkConnection),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        final content = _buildSection();
        if (narrow) {
          return Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
                child: Row(
                  children: [
                    SubNavMenu(
                      items: _sections,
                      index: _selected,
                      onChanged: (value) => setState(() => _selected = value),
                    ),
                    const Spacer(),
                    Text(
                      _engine == null ? '' : _engine!,
                      style: TextStyle(fontSize: 11, color: hampanelMuted),
                    ),
                  ],
                ),
              ),
              Expanded(child: content),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SubNav(
              items: _sections,
              index: _selected,
              onChanged: (value) => setState(() => _selected = value),
            ),
            Expanded(child: content),
          ],
        );
      },
    );
  }

  Widget _buildSection() {
    switch (_selected) {
      case 0:
        return _OverviewSection(engine: _engine);
      case 1:
        return ContainersSection(engine: _engine);
      case 2:
        return const ComposeSection();
      case 3:
        return const ImagesSection();
      case 4:
        return const NetworksSection();
      case 5:
        return const VolumesSection();
      case 6:
        return const RegistriesSection();
      case 7:
        return const DockerSettingsSection();
      default:
        return _PlaceholderSection(
          title: _sections[_selected],
          message: '该子菜单正在实现中，稍后开放。',
        );
    }
  }
}

class _OverviewSection extends StatefulWidget {
  const _OverviewSection({this.engine});

  final String? engine;

  @override
  State<_OverviewSection> createState() => _OverviewSectionState();
}

class _OverviewSectionState extends State<_OverviewSection> {
  DockerOverview? _overview;
  String? _error;
  bool _loading = true;

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
      final json = await _api.getJson('/api/v1/docker/overview');
      if (!mounted) return;
      setState(() {
        _overview = DockerOverview.fromJson(json as Map<String, dynamic>);
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

  @override
  Widget build(BuildContext context) {
    final overview = _overview;
    return Column(
      children: [
        PageHeader(
          title: '概览',
          subtitle: overview == null
              ? '容器运行状态汇总'
              : '${overview.engine} · ${overview.running} 个运行中容器',
          actions: [
            IconButton(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  children: [
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _MetricCard(
                          label: '运行中',
                          value: overview?.running ?? 0,
                          icon: Icons.play_circle_outline,
                          color: hampanelAccent,
                        ),
                        _MetricCard(
                          label: '已停止',
                          value: overview?.stopped ?? 0,
                          icon: Icons.stop_circle_outlined,
                          color: hampanelMuted,
                        ),
                        _MetricCard(
                          label: '重启中',
                          value: overview?.restarting ?? 0,
                          icon: Icons.restart_alt,
                          color: hampanelWarning,
                        ),
                        _MetricCard(
                          label: '错误',
                          value: overview?.failed ?? 0,
                          icon: Icons.error_outline,
                          color: hampanelDanger,
                        ),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: [
                        _MetricCard(
                          label: '编排',
                          value: overview?.compose ?? 0,
                          icon: Icons.account_tree_outlined,
                        ),
                        _MetricCard(
                          label: '镜像',
                          value: overview?.images ?? 0,
                          icon: Icons.layers_outlined,
                        ),
                        _MetricCard(
                          label: '网络',
                          value: overview?.networks ?? 0,
                          icon: Icons.hub_outlined,
                        ),
                        _MetricCard(
                          label: '存储卷',
                          value: overview?.volumes ?? 0,
                          icon: Icons.save_outlined,
                        ),
                      ],
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.label,
    required this.value,
    required this.icon,
    this.color,
  });

  final String label;
  final int value;
  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final effectiveColor = color ?? hampanelInk;
    return Container(
      width: 168,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: hampanelSurface,
        border: Border.all(color: hampanelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: effectiveColor),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '$value',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: effectiveColor,
            ),
          ),
        ],
      ),
    );
  }
}

class _PlaceholderSection extends StatelessWidget {
  const _PlaceholderSection({required this.title, required this.message});

  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(title: title),
        Expanded(
          child: EmptyState(
            icon: Icons.construction_outlined,
            title: '正在实现',
            message: message,
          ),
        ),
      ],
    );
  }
}
