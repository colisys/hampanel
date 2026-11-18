import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/nix_status.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/layout.dart';
import '../../ui/widgets.dart';
import 'deploy_dialog.dart';

class NixTab extends StatefulWidget {
  const NixTab({super.key});

  @override
  State<NixTab> createState() => _NixTabState();
}

class _NixTabState extends State<NixTab> {
  NixStatus? _status;
  bool _loading = true;
  String? _error;
  String? _busy;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

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
      final json = await _api.getJson('/api/v1/store/nix');
      if (!mounted) return;
      setState(() {
        _status = NixStatus.fromJson(json as Map<String, dynamic>);
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

  Future<void> _installNix() async {
    setState(() => _busy = 'install');
    try {
      final json = await _api.postJson(
        '/api/v1/store/packages/nix/install',
        const {},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      await showOutputDialog(
        context,
        map['ok'] == true ? 'Nix 安装完成' : 'Nix 安装失败',
        map['output'] as String? ?? '',
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(error))));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _run(String target, bool build) async {
    setState(() => _busy = '$target-${build ? 'build' : 'run'}');
    try {
      final json = await _api.postJson(
        build ? '/api/v1/store/nix/build' : '/api/v1/store/nix/run',
        {'target': target},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(
          context,
          '${build ? '构建' : '运行'}失败',
          map['output'] as String? ?? '',
        );
      } else {
        await showOutputDialog(
          context,
          '$target ${build ? '构建输出' : '运行输出'}',
          map['output'] as String? ?? '',
        );
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(describeError(error))));
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _runCustom(bool build) async {
    final target = _custom.text.trim();
    if (target.isEmpty) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('请输入 nixpkgs 属性名')));
      return;
    }
    await _run(target, build);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return LoadingView();
    if (_error != null) {
      return SingleChildScrollView(
        child: ErrorBanner(message: _error!, onRetry: _load),
      );
    }
    final status = _status;
    if (status == null) {
      return EmptyState(icon: Icons.ac_unit, title: 'Nix 状态未知');
    }

    return ListView(
      padding: pageContentPadding(context, top: 8),
      children: [
        PanelCard(
          title: 'Nix 环境',
          trailing: StatusPill(
            text: status.available ? '可用' : '未安装',
            good: status.available,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (status.available) ...[
                Text(status.version, style: monospace),
                const SizedBox(height: 6),
                Text(
                  status.flakes
                      ? 'Flake 与 nix-command 已启用，可执行 nix build / nix run。'
                      : '已检测到 Nix，但 flakes 实验特性可能未启用。',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
              ] else
                Text(
                  '未检测到 nix。可直接在应用商店安装，或使用服务器发行版的包管理器。'
                  '命令仅允许执行内置的精选属性，避免任意表达式执行。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                children: [
                  if (!status.available)
                    FilledButton.icon(
                      onPressed: _busy == 'install' ? null : _installNix,
                      icon: const Icon(Icons.download, size: 16),
                      label: Text(_busy == 'install' ? '安装中…' : '安装 Nix'),
                    ),
                  OutlinedButton.icon(
                    onPressed: _busy == null ? _load : null,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('重新检测'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        PanelCard(
          title: '自定义 Nix 属性',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '输入 nixpkgs 属性名（例如 hello、nodejs_22、python311Packages.requests）。'
                '不接受 URL、flake 引用或 shell 元字符。',
                style: TextStyle(
                  fontSize: 11.5,
                  color: hampanelMuted,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 10),
              FieldWithActions(
                field: TextField(
                  controller: _custom,
                  style: monospace,
                  decoration: const InputDecoration(
                    labelText: 'nixpkgs#属性',
                    hintText: 'nodejs_22',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _runCustom(true),
                ),
                actions: [
                  OutlinedButton(
                    onPressed: status.available && _busy == null
                        ? () => _runCustom(true)
                        : null,
                    child: const Text('构建'),
                  ),
                  FilledButton(
                    onPressed: status.available && _busy == null
                        ? () => _runCustom(false)
                        : null,
                    child: const Text('运行'),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        for (final target in status.targets)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Icon(Icons.ac_unit, size: 18, color: hampanelMuted),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'nixpkgs#${target.id}',
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            target.description,
                            style: TextStyle(
                              fontSize: 11.5,
                              color: hampanelMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_busy == '${target.id}-build')
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    OutlinedButton(
                      onPressed: status.available && _busy == null
                          ? () => _run(target.id, true)
                          : null,
                      child: const Text('构建'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: status.available && _busy == null
                          ? () => _run(target.id, false)
                          : null,
                      child: const Text('运行'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}
