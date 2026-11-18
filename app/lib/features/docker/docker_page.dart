import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'compose_section.dart';
import 'containers_section.dart';
import 'images_section.dart';
import 'networks_section.dart';
import 'registries_section.dart';
import 'settings_section.dart';
import 'volumes_section.dart';


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

  List<String> get _sectionLabels => [
    '概览',
    '容器列表',
    '编排管理',
    '镜像管理',
    '网络管理',
    '存储卷',
    '源管理',
    _engine == 'podman' ? 'Podman 设置' : 'Docker 设置',
  ];

  ApiClient get _api => PanelScope.of(context).api;

  String get _engineLabel => _engine == 'podman' ? 'Podman' : 'Docker';

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
      String? configured;
      if (error.code == 'engine_unavailable') {
        try {
          final settings = await _api.getJson('/api/v1/docker/settings');
          if (settings is Map<String, dynamic>) {
            configured = settings['engine'] as String?;
          }
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() {
        _engine = configured ?? _engine;
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

  Future<void> _installEngine() async {
    final package = _engine == 'podman' ? 'podman' : 'docker';
    final label = package == 'podman' ? 'Podman' : 'Docker';
    setState(() => _installing = true);
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'package.install',
        title: '安装 $label',
        params: {'id': package},
      );
      if (!mounted) return;
      _toast('已提交任务：${task.title}');
      unawaited(center.waitFor(task.id).then((_) async {
        if (!mounted) return;
        await _checkConnection();
      }));
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppSnackBar(context, SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const LoadingView();
    }
    if (_engineMissing) {
      return Column(
        children: [
          PageHeader(
            title: '容器',
            subtitle: '未检测到 $_engineLabel',
          ),
          Expanded(
            child: EmptyState(
              icon: Icons.widgets_outlined,
              title: '还没有容器运行时',
              message:
                  '容器、运行环境和应用商店的 Compose 应用都依赖 $_engineLabel。'
                  '可以在应用商店安装 $_engineLabel，或直接点击下面的按钮。',
              action: FilledButton.icon(
                onPressed: _installing ? null : _installEngine,
                icon: _installing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.download_outlined, size: 16),
                label: Text(_installing ? '安装中…' : '安装 $_engineLabel'),
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
              Expanded(child: content),
              Container(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: hampanelBorder)),
                ),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: SafeArea(
                  top: false,
                  child: Row(
                    children: [
                      SubNavMenu(
                        items: _sectionLabels,
                        index: _selected,
                        onChanged: (value) =>
                            setState(() => _selected = value),
                      ),
                      const Spacer(),
                      Text(
                        _engine == null ? '' : _engine!,
                        style: TextStyle(fontSize: 11, color: hampanelMuted),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SubNav(
              items: _sectionLabels,
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
        return RegistriesSection(engine: _engine);
      case 7:
        return DockerSettingsSection(engine: _engine);
      default:
        return _PlaceholderSection(
          title: _sectionLabels[_selected],
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
            PageRefreshButton(onPressed: _load),
          ],
        ),
        if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
        Expanded(
          child: _loading
              ? const LoadingView()
              : ListView(
                  padding: pageContentPadding(context, top: 8),
                  children: [
                    MetricGrid(
                      metrics: [
                        MetricCard(
                          label: '运行中',
                          value: '${overview?.running ?? 0}',
                          icon: Icons.play_circle_outline,
                          accent: hampanelAccent,
                        ),
                        MetricCard(
                          label: '已停止',
                          value: '${overview?.stopped ?? 0}',
                          icon: Icons.stop_circle_outlined,
                          accent: hampanelMuted,
                        ),
                        MetricCard(
                          label: '重启中',
                          value: '${overview?.restarting ?? 0}',
                          icon: Icons.restart_alt,
                          accent: hampanelWarning,
                        ),
                        MetricCard(
                          label: '错误',
                          value: '${overview?.failed ?? 0}',
                          icon: Icons.error_outline,
                          accent: hampanelDanger,
                        ),
                        MetricCard(
                          label: '编排',
                          value: '${overview?.compose ?? 0}',
                          icon: Icons.account_tree_outlined,
                        ),
                        MetricCard(
                          label: '镜像',
                          value: '${overview?.images ?? 0}',
                          icon: Icons.layers_outlined,
                        ),
                        MetricCard(
                          label: '网络',
                          value: '${overview?.networks ?? 0}',
                          icon: Icons.hub_outlined,
                        ),
                        MetricCard(
                          label: '存储卷',
                          value: '${overview?.volumes ?? 0}',
                          icon: Icons.save_outlined,
                        ),
                      ],
                    ),
                  ],
                )
        ),
      ],
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
