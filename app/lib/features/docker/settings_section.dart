import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class DockerSettingsSection extends StatefulWidget {
  const DockerSettingsSection({super.key});

  @override
  State<DockerSettingsSection> createState() => _DockerSettingsSectionState();
}

class _DockerSettingsSectionState extends State<DockerSettingsSection> {
  final _mirrors = TextEditingController();
  final _insecure = TextEditingController();
  final _cidr = TextEditingController();
  final _logSize = TextEditingController(text: '10m');
  final _logFile = TextEditingController(text: '3');
  final _socket = TextEditingController();
  bool _ipv6 = false;
  bool _experimental = false;
  bool _iptables = true;
  bool _liveRestore = false;
  bool _nvidia = false;
  String _logDriver = 'json-file';
  String _cgroup = 'systemd';
  String _path = '';
  bool _loading = true;
  bool _saving = false;
  String? _error;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _mirrors.dispose();
    _insecure.dispose();
    _cidr.dispose();
    _logSize.dispose();
    _logFile.dispose();
    _socket.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/docker/settings');
      final settings = DockerSettings.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _path = settings.path;
        _mirrors.text = settings.registryMirrors.join('\n');
        _insecure.text = settings.insecureRegistries.join('\n');
        _cidr.text = settings.fixedCidrV6;
        _logSize.text = settings.logMaxSize;
        _logFile.text = settings.logMaxFile;
        _socket.text = settings.socketPath;
        _ipv6 = settings.ipv6;
        _experimental = settings.experimental;
        _iptables = settings.iptables;
        _liveRestore = settings.liveRestore;
        _nvidia = settings.nvidiaRuntime;
        _logDriver = settings.logDriver;
        _cgroup = settings.cgroupDriver;
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

  Future<void> _save() async {
    final ok = await confirmDialog(
      context,
      title: '应用 Docker 设置?',
      message: '会写入 daemon.json 并重启 Docker。'
          '未开启 Live Restore 时，重启会停止运行中的容器。',
      confirmLabel: '应用并重启',
      danger: true,
    );
    if (!ok) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final json = await _api.putJson('/api/v1/docker/settings', {
        'registry_mirrors': _lines(_mirrors.text),
        'insecure_registries': _lines(_insecure.text),
        'ipv6': _ipv6,
        'experimental': _experimental,
        'fixed_cidr_v6': _cidr.text.trim(),
        'log_driver': _logDriver,
        'log_max_size': _logSize.text.trim(),
        'log_max_file': _logFile.text.trim(),
        'iptables': _iptables,
        'live_restore': _liveRestore,
        'cgroup_driver': _cgroup,
        'nvidia_runtime': _nvidia,
        'socket_path': _socket.text.trim(),
        'restart': true,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      final output = (map['output'] as String? ?? '').trim();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            map['ok'] == true
                ? (output.isEmpty ? '设置已应用' : output)
                : (output.isEmpty ? '应用失败' : output),
          ),
        ),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: 'Docker 设置',
          subtitle: _path.isEmpty ? 'daemon.json 与连接参数' : _path,
          actions: [
            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '应用中…' : '应用'),
            ),
            const SizedBox(width: 8),
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
                    _Section(
                      title: '容器加速',
                      child: TextField(
                        controller: _mirrors,
                        minLines: 2,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: '镜像加速地址（每行一个）',
                          hintText: 'https://mirror.example.com',
                        ),
                      ),
                    ),
                    _Section(
                      title: '私有仓库',
                      child: TextField(
                        controller: _insecure,
                        minLines: 2,
                        maxLines: 6,
                        decoration: const InputDecoration(
                          labelText: '受信任的 HTTP 仓库（每行一个）',
                          hintText: 'registry.internal:5000',
                        ),
                      ),
                    ),
                    _Section(
                      title: 'IPv6',
                      child: Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('启用 IPv6'),
                            value: _ipv6,
                            onChanged: (value) =>
                                setState(() => _ipv6 = value),
                          ),
                          TextField(
                            controller: _cidr,
                            decoration: const InputDecoration(
                              labelText: 'IPv6 子网（可选）',
                              hintText: 'fd00::/64',
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: '日志轮转切割',
                      child: Column(
                        children: [
                          DropdownButtonFormField<String>(
                            initialValue: _logDriver,
                            decoration: const InputDecoration(
                              labelText: '日志驱动',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'json-file',
                                child: Text('json-file'),
                              ),
                              DropdownMenuItem(
                                value: 'local',
                                child: Text('local'),
                              ),
                              DropdownMenuItem(
                                value: 'journald',
                                child: Text('journald'),
                              ),
                              DropdownMenuItem(
                                value: 'syslog',
                                child: Text('syslog'),
                              ),
                              DropdownMenuItem(
                                value: 'none',
                                child: Text('none'),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _logDriver = value ?? 'json-file'),
                          ),
                          const SizedBox(height: 10),
                          Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _logSize,
                                  decoration: const InputDecoration(
                                    labelText: '单文件上限',
                                    hintText: '10m',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: TextField(
                                  controller: _logFile,
                                  decoration: const InputDecoration(
                                    labelText: '保留文件数',
                                    hintText: '3',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: '网络与守护进程',
                      child: Column(
                        children: [
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('iptables'),
                            subtitle: const Text('允许 Docker 管理主机防火墙规则'),
                            value: _iptables,
                            onChanged: (value) =>
                                setState(() => _iptables = value),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Live Restore'),
                            subtitle: const Text('重启 Docker 时保持容器运行'),
                            value: _liveRestore,
                            onChanged: (value) =>
                                setState(() => _liveRestore = value),
                          ),
                          DropdownButtonFormField<String>(
                            initialValue: _cgroup,
                            decoration: const InputDecoration(
                              labelText: 'Cgroup Driver',
                            ),
                            items: const [
                              DropdownMenuItem(
                                value: 'systemd',
                                child: Text('systemd'),
                              ),
                              DropdownMenuItem(
                                value: 'cgroupfs',
                                child: Text('cgroupfs'),
                              ),
                            ],
                            onChanged: (value) =>
                                setState(() => _cgroup = value ?? 'systemd'),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('NVIDIA GPU 支持'),
                            subtitle: const Text(
                              '写入 nvidia-container-runtime 并设为默认运行时',
                            ),
                            value: _nvidia,
                            onChanged: (value) =>
                                setState(() => _nvidia = value),
                          ),
                          SwitchListTile(
                            contentPadding: EdgeInsets.zero,
                            title: const Text('experimental'),
                            value: _experimental,
                            onChanged: (value) =>
                                setState(() => _experimental = value),
                          ),
                        ],
                      ),
                    ),
                    _Section(
                      title: 'Socket 路径',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          TextField(
                            controller: _socket,
                            decoration: const InputDecoration(
                              labelText: 'Docker / Podman 连接地址（可选）',
                              hintText: 'unix:///var/run/docker.sock',
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '仅用于 hampanel 连接引擎，不会修改 dockerd 的监听参数。',
                            style: TextStyle(
                              fontSize: 10.5,
                              color: hampanelMuted,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: hampanelSurface,
          border: Border.all(color: hampanelBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

List<String> _lines(String value) => value
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList();
