import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/tunnel_profile.dart';
import '../../core/session.dart';
import '../../core/tunnel_store.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'tunnel_runner.dart';

class TunnelsPage extends StatefulWidget {
  const TunnelsPage({super.key, this.active = true});

  /// 只在页签激活时做 SSH 探测，避免隐藏页拉起进程。
  final bool active;

  @override
  State<TunnelsPage> createState() => _TunnelsPageState();
}

class _TunnelsPageState extends State<TunnelsPage> {
  List<TunnelProfile> _profiles = [];
  final Map<String, TunnelRuntime> _runtimes = {};
  bool _loading = true;
  bool _sshAvailable = false;
  bool _socatAvailable = false;
  String _sshVersion = '';
  String _socatVersion = '';
  String? _serverPlatform;
  String? _error;

  ApiClient get _api => PanelScope.of(context).api;
  bool get _socksSupported => Platform.isLinux && _serverPlatform == 'linux';

  @override
  void initState() {
    super.initState();
    if (widget.active) _load();
  }

  @override
  void didUpdateWidget(covariant TunnelsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active && !_loadedOnce) {
      _load();
    }
  }

  bool _loadedOnce = false;

  @override
  void dispose() {
    for (final runtime in _runtimes.values) {
      unawaited(TunnelRunner.stop(runtime));
    }
    super.dispose();
  }

  Future<void> _load() async {
    _loadedOnce = true;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final profiles = await TunnelStore.load();
      final ssh = await TunnelRunner.checkSsh();
      final socat = await TunnelRunner.checkSocat();
      String? platform;
      try {
        final json = await _api.getJson('/api/v1/system');
        platform = (json as Map<String, dynamic>)['platform'] as String?;
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _profiles = profiles;
        _sshAvailable = ssh.available;
        _sshVersion = ssh.version;
        _socatAvailable = socat.available;
        _socatVersion = socat.version;
        _serverPlatform = platform;
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

  String _defaultSshHost() {
    final endpoint = PanelScope.of(context).enrollment.endpoint.trim();
    if (endpoint.startsWith('[')) {
      final close = endpoint.indexOf(']');
      if (close > 1) return endpoint.substring(1, close);
    }
    final colon = endpoint.lastIndexOf(':');
    if (colon > 0) return endpoint.substring(0, colon);
    return endpoint;
  }

  Future<void> _create() async {
    final nameController = TextEditingController();
    final hostController = TextEditingController(text: _defaultSshHost());
    final sshPortController = TextEditingController(text: '22');
    final userController = TextEditingController(text: 'root');
    final keyController = TextEditingController();
    final jumpController = TextEditingController();
    final localPortController = TextEditingController(text: '1080');
    final remotePortController = TextEditingController(text: '8080');
    final targetHostController = TextEditingController(text: '127.0.0.1');
    final targetPortController = TextEditingController(text: '80');
    var mode = 'local';

    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新建端口穿透'),
          content: DialogBody(
            maxWidth: 640,
            maxHeight: 560,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _field(nameController, '名称'),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    decoration: const InputDecoration(labelText: '模式'),
                    items: [
                      const DropdownMenuItem(
                        value: 'local',
                        child: Text('-L 本地端口 → 远端目标'),
                      ),
                      const DropdownMenuItem(
                        value: 'remote',
                        child: Text('-R 远端端口 → 本地目标'),
                      ),
                      DropdownMenuItem(
                        value: 'socks',
                        enabled: _socksSupported,
                        child: Text(
                          _socksSupported
                              ? '-D 本地 SOCKS → 远端'
                              : '-D 本地 SOCKS（需双方 Linux）',
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'socat',
                        enabled: _socatAvailable,
                        child: Text(
                          _socatAvailable
                              ? 'socat 本地中继'
                              : 'socat 中继（未安装 socat）',
                        ),
                      ),
                    ],
                    onChanged: (value) {
                      if (value != null) setDialogState(() => mode = value);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _modeHelp(mode),
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (mode != 'socat') ...[
                    Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: _field(hostController, 'SSH 主机'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _field(
                            sshPortController,
                            'SSH 端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Expanded(child: _field(userController, 'SSH 用户')),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: _field(
                            keyController,
                            '私钥路径（可选）',
                            hint: '~/.ssh/id_ed25519',
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    _field(
                      jumpController,
                      '跳板机 -J（可选，单层）',
                      hint: 'ops@bastion.example.com:2222',
                    ),
                    const SizedBox(height: 10),
                  ],
                  if (mode == 'local') ...[
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            localPortController,
                            '本地监听端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: _field(targetHostController, '远端目标主机'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _field(
                            targetPortController,
                            '目标端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                  ] else if (mode == 'remote') ...[
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            remotePortController,
                            '远端监听端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: _field(targetHostController, '本地目标主机'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _field(
                            targetPortController,
                            '目标端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                  ] else if (mode == 'socks') ...[
                    SizedBox(
                      width: 220,
                      child: _field(
                        localPortController,
                        '本地 SOCKS 端口',
                        keyboard: TextInputType.number,
                      ),
                    ),
                  ] else ...[
                    Row(
                      children: [
                        Expanded(
                          child: _field(
                            localPortController,
                            '本地监听端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          flex: 2,
                          child: _field(targetHostController, '目标主机'),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _field(
                            targetPortController,
                            '目标端口',
                            keyboard: TextInputType.number,
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    '所有监听默认只绑定 127.0.0.1；SSH 使用 BatchMode、仅支持密钥/agent，'
                    '不支持密码。-R 的远端端口也绑定在远端回环地址。',
                    style: TextStyle(
                      fontSize: 11,
                      color: hampanelMuted,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );

    if (saved == true) {
      final profile = TunnelProfile(
        id: TunnelStore.newId(),
        name: nameController.text.trim(),
        mode: mode,
        sshHost: hostController.text.trim(),
        sshPort: int.tryParse(sshPortController.text.trim()) ?? 0,
        sshUser: userController.text.trim(),
        keyPath: keyController.text.trim(),
        jumpHost: jumpController.text.trim(),
        localPort: int.tryParse(localPortController.text.trim()) ?? 0,
        remotePort: int.tryParse(remotePortController.text.trim()) ?? 0,
        targetHost: targetHostController.text.trim(),
        targetPort: int.tryParse(targetPortController.text.trim()) ?? 0,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );
      try {
        TunnelRunner.validate(profile);
        if (mode == 'socks' && !_socksSupported) {
          throw ArgumentError('SOCKS 需要管理端与远端均为 Linux');
        }
        if (mode == 'socat' && !_socatAvailable) {
          throw ArgumentError('未安装 socat');
        }
        if (mode != 'socat' && !_sshAvailable) {
          throw ArgumentError('未找到 ssh 客户端');
        }
        if (profile.name.length > 64) {
          throw ArgumentError('名称不能超过 64 个字符');
        }
        _profiles.add(profile);
        await TunnelStore.save(_profiles);
        if (!mounted) return;
        setState(() {});
      } catch (error) {
        _toast(error.toString());
      }
    }

    nameController.dispose();
    hostController.dispose();
    sshPortController.dispose();
    userController.dispose();
    keyController.dispose();
    jumpController.dispose();
    localPortController.dispose();
    remotePortController.dispose();
    targetHostController.dispose();
    targetPortController.dispose();
  }

  String _modeHelp(String mode) {
    switch (mode) {
      case 'local':
        return '-L：在管理端 127.0.0.1 打开端口，通过 SSH 访问远端网络中的目标服务。';
      case 'remote':
        return '-R：在远端 127.0.0.1 打开端口，转发到管理端本地的目标服务。';
      case 'socks':
        return '-D：在管理端 127.0.0.1 提供 SOCKS5 代理，经 SSH 从远端出网。'
            '仅支持 Linux 管理端 + Linux 远端。';
      case 'socat':
        return 'socat：在管理端 127.0.0.1 监听并中继到目标地址（需要本地安装 socat）。';
      default:
        return '';
    }
  }

  Future<void> _start(TunnelProfile profile) async {
    if (profile.mode == 'socks' && !_socksSupported) {
      _toast('SOCKS 需要管理端与远端均为 Linux');
      return;
    }
    if (profile.mode == 'socat' && !_socatAvailable) {
      _toast('未安装 socat');
      return;
    }
    if (profile.mode != 'socat' && !_sshAvailable) {
      _toast('未找到 ssh 客户端');
      return;
    }
    final runtime = await TunnelRunner.start(profile);
    runtime.onChanged = () {
      if (mounted) setState(() {});
    };
    if (!mounted) return;
    setState(() => _runtimes[profile.id] = runtime);
    if (runtime.error != null) {
      await _showOutput('启动失败', runtime.error!);
    }
  }

  Future<void> _stop(TunnelProfile profile) async {
    final runtime = _runtimes[profile.id];
    if (runtime == null) return;
    await TunnelRunner.stop(runtime);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _remove(TunnelProfile profile) async {
    final ok = await confirmDialog(
      context,
      title: '删除隧道 ${profile.name}？',
      message: '会停止本地进程并删除管理端保存的配置。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    final runtime = _runtimes.remove(profile.id);
    if (runtime != null) await TunnelRunner.stop(runtime);
    _profiles.removeWhere((item) => item.id == profile.id);
    await TunnelStore.save(_profiles);
    if (mounted) setState(() {});
  }

  Future<void> _showLogs(TunnelProfile profile) async {
    final runtime = _runtimes[profile.id];
    final text = runtime == null || runtime.logs.isEmpty
        ? '隧道尚未启动，暂无日志。'
        : runtime.logs.toString();
    await _showOutput('${profile.name} 日志', text);
  }

  Future<void> _showOutput(String title, String text) async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: DialogBody(
          maxWidth: 760,
          maxHeight: 420,
          child: SingleChildScrollView(
            child: SelectableText(
              text.isEmpty ? '（无输出）' : text,
              style: monospace.copyWith(fontSize: 11.5),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '端口穿透',
          subtitle: '管理端 SSH 隧道：-L / -R / -D / -J，以及 socat 中继',
          actions: [
            FilledButton.icon(
              onPressed: _loading ? null : _create,
              icon: const Icon(Icons.add, size: 16),
              label: const Text('新建隧道'),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _load,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _error != null
              ? SingleChildScrollView(
                  child: ErrorBanner(message: _error!, onRetry: _load),
                )
              : ListView(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        StatusPill(
                          text: _sshAvailable ? 'SSH 可用' : 'SSH 不可用',
                          good: _sshAvailable,
                        ),
                        StatusPill(
                          text: _socatAvailable ? 'socat 可用' : 'socat 未安装',
                          good: _socatAvailable,
                        ),
                        StatusPill(
                          text: _socksSupported
                              ? 'SOCKS 可用'
                              : 'SOCKS 不可用（需双方 Linux）',
                          good: _socksSupported,
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '管理端 ${Platform.operatingSystem} · 远端 ${_serverPlatform ?? '未知'}'
                      '${_sshVersion.isNotEmpty ? ' · ${_sshVersion.split('\n').first}' : ''}'
                      '${_socatVersion.isNotEmpty ? ' · ${_socatVersion.split('\n').first}' : ''}',
                      style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                    ),
                    SizedBox(height: 12),
                    if (_profiles.isEmpty)
                      EmptyState(
                        icon: Icons.swap_horiz,
                        title: '还没有端口穿透配置',
                        message:
                            '支持本地转发、反向转发、SOCKS 和 socat 中继；'
                            '配置保存在管理端，不写入远端。',
                      )
                    else
                      for (final profile in _profiles) ...[
                        _card(profile),
                        const SizedBox(height: 10),
                      ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _card(TunnelProfile profile) {
    final runtime = _runtimes[profile.id];
    final running = runtime?.running ?? false;
    final modeLabel = switch (profile.mode) {
      'local' => '-L 本地转发',
      'remote' => '-R 反向转发',
      'socks' => '-D SOCKS',
      'socat' => 'socat 中继',
      _ => profile.mode,
    };
    final description = switch (profile.mode) {
      'local' =>
        '127.0.0.1:${profile.localPort} → ${profile.targetHost}:${profile.targetPort}（经 ${profile.sshHost}）',
      'remote' =>
        '远端 127.0.0.1:${profile.remotePort} → 本地 ${profile.targetHost}:${profile.targetPort}',
      'socks' => '127.0.0.1:${profile.localPort} SOCKS5 → ${profile.sshHost}',
      'socat' =>
        '127.0.0.1:${profile.localPort} → ${profile.targetHost}:${profile.targetPort}',
      _ => '',
    };
    final blocked =
        (profile.mode == 'socks' && !_socksSupported) ||
        (profile.mode == 'socat' && !_socatAvailable) ||
        (profile.mode != 'socat' && !_sshAvailable);

    return PanelCard(
      title: profile.name,
      trailing: Wrap(
        spacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          StatusPill(text: modeLabel, good: true),
          StatusPill(text: running ? '运行中' : '已停止', good: running),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            description,
            style: monospace.copyWith(fontSize: 12, color: hampanelMuted),
          ),
          if (profile.mode != 'socat') ...[
            const SizedBox(height: 4),
            Text(
              'ssh ${profile.sshUser}@${profile.sshHost}:${profile.sshPort}'
              '${profile.jumpHost.isNotEmpty ? '  -J ${profile.jumpHost}' : ''}'
              '${profile.keyPath.isNotEmpty ? '  -i ${profile.keyPath}' : ''}',
              style: TextStyle(fontSize: 11, color: hampanelMuted),
            ),
          ],
          if (runtime?.error != null) ...[
            const SizedBox(height: 6),
            Text(
              runtime!.error!,
              style: TextStyle(fontSize: 11.5, color: hampanelDanger),
            ),
          ],
          if (runtime?.exitCode != null && !running) ...[
            const SizedBox(height: 4),
            Text(
              '进程已退出，退出码 ${runtime!.exitCode}',
              style: TextStyle(fontSize: 11, color: hampanelDanger),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: [
              if (running)
                OutlinedButton.icon(
                  onPressed: () => _stop(profile),
                  icon: const Icon(Icons.stop, size: 15),
                  label: const Text('停止'),
                )
              else
                FilledButton.icon(
                  onPressed: blocked ? null : () => _start(profile),
                  icon: const Icon(Icons.play_arrow, size: 16),
                  label: const Text('启动'),
                ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: () => _showLogs(profile),
                icon: const Icon(Icons.article_outlined, size: 15),
                label: const Text('日志'),
              ),
              const Spacer(),
              if (blocked)
                Padding(
                  padding: EdgeInsets.only(right: 8),
                  child: Text(
                    '当前环境不可用',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ),
              IconButton(
                tooltip: '删除',
                onPressed: () => _remove(profile),
                icon: const Icon(Icons.delete_outline, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    String? hint,
    TextInputType? keyboard,
  }) {
    return TextField(
      controller: controller,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, hintText: hint),
    );
  }
}
