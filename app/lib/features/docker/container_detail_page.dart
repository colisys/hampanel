import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../ui/layout.dart';
import '../../ui/log_page.dart';
import '../../ui/remote_picker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'container_files_dialog.dart';
import 'container_terminal_dialog.dart';

/// Container configuration as a standalone page. Mirrors the image management
/// layout: header, scrollable tabs, list cards and a mobile action dock.
class ContainerDetailPage extends StatefulWidget {
  const ContainerDetailPage({
    super.key,
    required this.api,
    required this.containerId,
    this.initial,
  });

  final ApiClient api;
  final String containerId;
  final DockerContainer? initial;

  @override
  State<ContainerDetailPage> createState() => _ContainerDetailPageState();
}

class _ContainerDetailPageState extends State<ContainerDetailPage>
    with TickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  DockerContainerDetail? _detail;
  late String _lookup = widget.containerId;
  List<String> _networks = const [];
  bool _loading = false;
  bool _saving = false;
  String? _error;

  final _name = TextEditingController();
  final _ip = TextEditingController();
  final _mac = TextEditingController();
  final _hostname = TextEditingController();
  final _domainname = TextEditingController();
  final _user = TextEditingController();
  final _entrypoint = TextEditingController();
  final _command = TextEditingController();
  final _cpus = TextEditingController();
  final _memory = TextEditingController();
  final _restartMax = TextEditingController();
  String _network = '';
  String _restart = 'no';
  bool _tty = false;
  bool _stdinOpen = false;
  bool _privileged = false;
  final List<String> _dns = [];
  final List<String> _env = [];
  final List<String> _labels = [];
  final List<String> _addHosts = [];
  final List<DockerPort> _ports = [];
  final List<_MountEntry> _mounts = [];

  ApiClient get _api => widget.api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    _name.dispose();
    _ip.dispose();
    _mac.dispose();
    _hostname.dispose();
    _domainname.dispose();
    _user.dispose();
    _entrypoint.dispose();
    _command.dispose();
    _cpus.dispose();
    _memory.dispose();
    _restartMax.dispose();
    for (final mount in _mounts) {
      mount.dispose();
    }
    super.dispose();
  }

  Future<void> _load({String? savedName}) async {
    if (savedName == null && (_saving || _loading)) return;
    setState(() {
      if (savedName != null) {
        _lookup = savedName;
        _detail = null;
      }
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait<Object?>([
        _api.getJson('/api/v1/docker/containers/$_lookup'),
        _api.getJson('/api/v1/docker/networks').catchError(
          (Object _) => <String, dynamic>{},
        ),
      ]);
      if (!mounted) return;
      final detail = DockerContainerDetail.fromJson(
        results[0] as Map<String, dynamic>,
      );
      final networkMap = results[1] as Map<String, dynamic>? ?? const {};
      setState(() {
        _detail = detail;
        if (detail.name.isNotEmpty) _lookup = detail.name;
        _networks = ((networkMap['networks'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map((entry) => entry['name'] as String? ?? '')
            .where((name) => name.isNotEmpty)
            .toList();
        _applyDetail(detail);
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

  void _applyDetail(DockerContainerDetail detail) {
    for (final mount in _mounts) {
      mount.dispose();
    }
    _mounts.clear();

    _name.text = detail.name;
    _ip.text = detail.ip;
    _mac.text = detail.macAddress;
    _hostname.text = detail.hostname;
    _domainname.text = detail.domainname;
    _user.text = detail.user;
    _entrypoint.text = detail.entrypoint.isEmpty
        ? ''
        : detail.entrypoint.first;
    // Docker's --entrypoint replaces the entrypoint with a single value, so
    // the remaining entrypoint arguments stay in front of the command.
    _command.text = [
      ...detail.entrypoint.skip(1),
      ...detail.command,
    ].join(' ');
    _cpus.text = detail.cpus == null ? '' : '${detail.cpus}';
    _memory.text = detail.memory == null
        ? ''
        : '${detail.memory! ~/ (1024 * 1024)}';
    _restartMax.text = detail.restartMax > 0 ? '${detail.restartMax}' : '';
    _restart = switch (detail.restartPolicy) {
      '' => 'no',
      'on-failure' => 'on-failure',
      'always' => 'always',
      'unless-stopped' => 'unless-stopped',
      _ => 'no',
    };
    _network = detail.networkMode == 'default' ? '' : detail.networkMode;
    _tty = detail.tty;
    _stdinOpen = detail.stdinOpen;
    _privileged = detail.privileged;
    _dns
      ..clear()
      ..addAll(detail.dns);
    _env
      ..clear()
      ..addAll(detail.env);
    _labels
      ..clear()
      ..addAll(detail.labels);
    _addHosts
      ..clear()
      ..addAll(detail.addHosts);
    _ports
      ..clear()
      ..addAll(detail.ports);
    for (final mount in detail.mounts) {
      _mounts.add(
        _MountEntry(
          type: mount.type == 'bind' ? 'bind' : 'volume',
          source: mount.type == 'volume' && mount.name.isNotEmpty
              ? mount.name
              : mount.source,
          destination: mount.destination,
          readOnly: mount.readOnly,
        ),
      );
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppSnackBar(context, SnackBar(content: Text(message)));
  }

  Future<void> _save() async {
    final detail = _detail;
    if (detail == null || _loading || _saving) return;
    if (detail.composeProject.isNotEmpty) {
      _toast('Compose 管理的容器请在编排页面修改');
      return;
    }
    final name = _name.text.trim();
    if (!RegExp(r'^[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}$').hasMatch(name)) {
      _toast('容器名称无效');
      return;
    }
    if (_ip.text.trim().isNotEmpty &&
        InternetAddress.tryParse(_ip.text.trim()) == null) {
      _toast('IP 地址无效');
      return;
    }
    if (_mac.text.trim().isNotEmpty &&
        !RegExp(r'^(?:[0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$')
            .hasMatch(_mac.text.trim())) {
      _toast('MAC 地址无效');
      return;
    }
    final cpus = double.tryParse(_cpus.text.trim());
    final memoryMb = int.tryParse(_memory.text.trim());
    final restart = _restart == 'on-failure' &&
            int.tryParse(_restartMax.text.trim()) != null
        ? 'on-failure:${int.parse(_restartMax.text.trim())}'
        : _restart;
    final body = <String, dynamic>{
      'name': name,
      'image': detail.image,
      'command': _splitCommand(_command.text),
      'entrypoint': _entrypoint.text.trim(),
      'env': [..._env],
      'ports': [for (final port in _ports) _portSpec(port)],
      'mounts': [for (final mount in _mounts) ?mount.spec],
      'restart': restart,
      'network': _network == 'default' ? '' : _network,
      'labels': [..._labels],
      'cpus': ?cpus,
      'memory': memoryMb == null ? null : memoryMb * 1024 * 1024,
      'hostname': _hostname.text.trim(),
      'domainname': _domainname.text.trim(),
      'user': _user.text.trim(),
      'tty': _tty,
      'stdin_open': _stdinOpen,
      'privileged': _privileged,
      'dns': [..._dns],
      'add_hosts': [..._addHosts],
      'ip': _ip.text.trim(),
      'mac_address': _mac.text.trim(),
    };
    final ok = await confirmDialog(
      context,
      title: '保存并重建 $name?',
      message: '容器不能原地修改。保存后会停止旧容器并按新配置重建，旧配置会备份在数据目录。',
      confirmLabel: '重建',
      danger: true,
    );
    if (!ok || !mounted) return;
    setState(() => _saving = true);
    try {
      await _api.postJson(
        '/api/v1/docker/containers/${detail.id}/recreate',
        body,
      );
      if (!mounted) return;
      _toast('容器已重建');
      await _load(savedName: name);
    } on ApiException catch (error) {
      _toast(error.message);
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _logs() async {
    final api = _api;
    final name = _detail?.name ?? _lookup;
    final id = _detail?.id ?? _lookup;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LogPage(
          title: '$name 日志',
          emptyMessage: '暂无日志',
          load: (lines) async {
            final json = await api.getJson(
              '/api/v1/docker/containers/$id/logs',
              query: {'lines': '$lines'},
            );
            final map = json as Map<String, dynamic>? ?? const {};
            return LogPageData(content: map['output'] as String? ?? '');
          },
        ),
      ),
    );
  }

  Future<void> _terminal() async {
    final container = _detail;
    if (container == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ContainerTerminalDialog(
        api: _api,
        container: DockerContainer(
          id: container.id,
          name: container.name,
          image: container.image,
          state: container.state,
          status: container.status,
          ports: '',
          createdAt: container.createdAt,
        ),
      ),
    );
  }

  Future<void> _files() async {
    final container = _detail;
    if (container == null) return;
    await showDialog<void>(
      context: context,
      builder: (_) => ContainerFilesDialog(
        api: _api,
        container: DockerContainer(
          id: container.id,
          name: container.name,
          image: container.image,
          state: container.state,
          status: container.status,
          ports: '',
          createdAt: container.createdAt,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final detail = _detail;
    final running = detail?.state == 'running';
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              detail?.name ?? (_lookup == widget.containerId
                  ? widget.initial?.name ?? '容器详情'
                  : _lookup),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (detail != null)
              Text(
                '${detail.image} · ${detail.state}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 10.5, color: hampanelMuted),
              ),
          ],
        ),
        actions: [
          if (!compact) ...[
            TextButton.icon(
              onPressed: detail == null ? null : _logs,
              icon: const Icon(Icons.receipt_long_outlined, size: 16),
              label: const Text('日志'),
            ),
            TextButton.icon(
              onPressed: running ? _terminal : null,
              icon: const Icon(Icons.terminal, size: 16),
              label: const Text('终端'),
            ),
            TextButton.icon(
              onPressed: running ? _files : null,
              icon: const Icon(Icons.folder_open_outlined, size: 16),
              label: const Text('文件'),
            ),
            const SizedBox(width: 6),
            FilledButton.icon(
              onPressed: detail == null || _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '保存中…' : '保存并重建'),
            ),
            const SizedBox(width: 8),
          ] else
            PageRefreshButton(onPressed: _load),
        ],
      ),
      body: Column(
        children: [
          if (_error != null) ErrorBanner(message: _error!, onRetry: _load),
          if (_loading)
            const Expanded(child: LoadingView())
          else if (detail == null)
            const Expanded(
              child: EmptyState(
                icon: Icons.inventory_2_outlined,
                title: '容器不存在',
                message: '它可能已被删除。',
              ),
            )
          else ...[
            if (detail.composeProject.isNotEmpty)
              Padding(
                padding: pageContentPadding(context, top: 6),
                child: ErrorBanner(
                  message: '该容器由 Compose（${detail.composeProject}）管理，'
                      '请在编排页面修改，这里只读。',
                  onRetry: _load,
                ),
              ),
            TabBar(
              controller: _tabs,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              tabs: const [
                Tab(text: '网络'),
                Tab(text: '资源管理'),
                Tab(text: '主机映射'),
                Tab(text: '启动参数'),
                Tab(text: '环境'),
              ],
            ),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [
                  _networkTab(detail),
                  _resourceTab(detail),
                  _hostsTab(),
                  _startupTab(),
                  _envTab(),
                ],
              ),
            ),
            if (compact) ...[
              _quickBar(running),
              ActionDock(
                actions: [
                  ActionDockItem(
                    icon: Icons.save_outlined,
                    label: '保存',
                    onPressed:
                        _saving || detail.composeProject.isNotEmpty
                        ? null
                        : _save,
                  ),
                  ActionDockItem(
                    icon: Icons.receipt_long_outlined,
                    label: '日志',
                    onPressed: _logs,
                  ),
                  ActionDockItem(
                    icon: Icons.terminal,
                    label: '终端',
                    onPressed: running ? _terminal : null,
                  ),
                  ActionDockItem(
                    icon: Icons.folder_open_outlined,
                    label: '文件',
                    onPressed: running ? _files : null,
                  ),
                  ActionDockItem(
                    icon: Icons.refresh,
                    label: '刷新',
                    onPressed: _load,
                  ),
                ],
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _quickBar(bool running) {
    return Container(
      decoration: BoxDecoration(
        color: hampanelSurface,
        border: Border(top: BorderSide(color: hampanelBorder)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      child: Row(
        children: [
          Icon(
            running ? Icons.play_circle_outline : Icons.stop_circle_outlined,
            size: 16,
            color: running ? hampanelAccent : hampanelMuted,
          ),
          const SizedBox(width: 6),
          Text(
            running ? '运行中' : '已停止',
            style: TextStyle(fontSize: 11.5, color: hampanelMuted),
          ),
          const Spacer(),
          Text(
            '重建后生效',
            style: TextStyle(fontSize: 11, color: hampanelMuted),
          ),
        ],
      ),
    );
  }

  Widget _tabList(List<Widget> children) {
    return ListView(
      padding: pageContentPadding(context, top: 8),
      children: children,
    );
  }

  Widget _networkTab(DockerContainerDetail detail) {
    return _tabList([
      PanelCard(
        title: '网络',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _name,
              readOnly: detail.composeProject.isNotEmpty,
              decoration: const InputDecoration(labelText: '容器名称'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _network.isEmpty ? '' : _network,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: '使用的网络',
                isDense: true,
              ),
              items: [
                const DropdownMenuItem(value: '', child: Text('默认（bridge）')),
                for (final network in {
                  _network,
                  ..._networks,
                  ...detail.networks.map((entry) => entry.name),
                }.where((name) => name.isNotEmpty))
                  DropdownMenuItem(value: network, child: Text(network)),
              ],
              onChanged: (value) => setState(() => _network = value ?? ''),
            ),
            const SizedBox(height: 12),
            FormRow(
              children: [
                TextField(
                  controller: _hostname,
                  decoration: const InputDecoration(
                    labelText: '主机名',
                    hintText: '留空使用容器 ID',
                    isDense: true,
                  ),
                ),
                TextField(
                  controller: _domainname,
                  decoration: const InputDecoration(
                    labelText: 'Domain',
                    hintText: 'example.internal',
                    isDense: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            FormRow(
              children: [
                TextField(
                  controller: _ip,
                  readOnly: detail.composeProject.isNotEmpty,
                  decoration: const InputDecoration(labelText: '静态 IP 地址'),
                ),
                TextField(
                  controller: _mac,
                  readOnly: detail.composeProject.isNotEmpty,
                  decoration: const InputDecoration(labelText: 'MAC 地址'),
                ),
              ],
            ),
            if (detail.networks.isNotEmpty) ...[
              const SizedBox(height: 14),
              for (final network in detail.networks)
                _readonlyRow(
                  network.name,
                  network.ip.isEmpty && network.mac.isEmpty
                      ? '—'
                      : [
                          if (network.ip.isNotEmpty) 'IP ${network.ip}',
                          if (network.mac.isNotEmpty) 'MAC ${network.mac}',
                        ].join(' · '),
                ),
            ],
          ],
        ),
      ),
      const SizedBox(height: 12),
      PanelCard(
        title: 'DNS',
        child: _stringChips(
          values: _dns,
          emptyText: '没有自定义 DNS，使用容器引擎默认值',
          hint: '例如 1.1.1.1 或 8.8.8.8',
          onAdd: () async {
            final value = await _input('添加 DNS', 'DNS 服务器地址');
            if (value != null) setState(() => _dns.add(value));
          },
          onRemove: (index) => setState(() => _dns.removeAt(index)),
        ),
      ),
      const SizedBox(height: 12),
      PanelCard(
        title: '端口映射',
        trailing: TextButton.icon(
          onPressed: () => _editPort(),
          icon: const Icon(Icons.add, size: 15),
          label: const Text('添加'),
        ),
        child: _ports.isEmpty
            ? Text(
                '没有端口映射。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              )
            : Column(
                children: [
                  for (var index = 0; index < _ports.length; index++)
                    _portRow(index),
                ],
              ),
      ),
    ]);
  }

  Widget _portRow(int index) {
    return _editableRow(
      label: _portSpec(_ports[index]),
      onEdit: () => _editPort(index),
      onRemove: () => setState(() => _ports.removeAt(index)),
    );
  }

  Future<void> _editPort([int? index]) async {
    final initial = index == null ? null : _ports[index];
    var hostIp = initial?.hostIp ?? '';
    if (hostIp.startsWith('[') && hostIp.endsWith(']')) {
      hostIp = hostIp.substring(1, hostIp.length - 1);
    }
    var hostPort = initial?.hostPort ?? '';
    var containerPort = initial?.containerPort ?? '';
    var protocol = initial?.protocol ?? 'tcp';
    if (protocol.isEmpty) protocol = 'tcp';
    final form = GlobalKey<FormState>();
    final port = await showDialog<DockerPort>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(index == null ? '添加端口映射' : '编辑端口映射'),
        content: DialogBody(
          maxWidth: 420,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  initialValue: hostIp,
                  decoration: const InputDecoration(labelText: '主机 IP'),
                  onChanged: (value) => hostIp = value.trim(),
                  validator: (_) => hostIp.isEmpty ||
                          InternetAddress.tryParse(hostIp) != null
                      ? null
                      : 'IP 地址无效',
                ),
                TextFormField(
                  initialValue: hostPort,
                  decoration: const InputDecoration(
                    labelText: '主机端口',
                    hintText: '留空自动分配',
                  ),
                  onChanged: (value) => hostPort = value.trim(),
                  validator: (_) => hostPort.isEmpty || _validPort(hostPort)
                      ? null
                      : '端口无效',
                ),
                TextFormField(
                  initialValue: containerPort,
                  decoration: const InputDecoration(labelText: '容器端口'),
                  onChanged: (value) => containerPort = value.trim(),
                  validator: (_) => _validPort(containerPort) ? null : '端口无效',
                ),
                DropdownButtonFormField<String>(
                  initialValue: protocol,
                  decoration: const InputDecoration(labelText: '协议'),
                  items: [
                    for (final value in {'tcp', 'udp', 'sctp', protocol})
                      DropdownMenuItem(value: value, child: Text(value)),
                  ],
                  onChanged: (value) => protocol = value ?? 'tcp',
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (!form.currentState!.validate()) return;
              Navigator.of(context).pop(DockerPort(
                hostIp: hostIp,
                hostPort: hostPort,
                containerPort: containerPort,
                protocol: protocol,
              ));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (port == null || !mounted) return;
    setState(() {
      if (index == null) {
        _ports.add(port);
      } else {
        _ports[index] = port;
      }
    });
  }

  bool _validPort(String value) {
    final bounds = value.split('-');
    if (bounds.length > 2 || !RegExp(r'^\d+(?:-\d+)?$').hasMatch(value)) {
      return false;
    }
    final low = int.tryParse(bounds.first) ?? 0;
    final high = int.tryParse(bounds.last) ?? 0;
    return low > 0 && high >= low && high <= 65535;
  }

  String _portSpec(DockerPort port) {
    final ip = port.hostIp;
    final host = ip.contains(':') && !ip.startsWith('[') ? '[$ip]' : ip;
    final prefix = host.isEmpty ? '' : '$host:';
    final protocol = port.protocol.isEmpty ? 'tcp' : port.protocol;
    return '$prefix${port.hostPort}:${port.containerPort}/$protocol';
  }

  Widget _resourceTab(DockerContainerDetail detail) {
    return _tabList([
      PanelCard(
        title: '资源限制',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            FormRow(
              children: [
                TextField(
                  controller: _cpus,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'CPU 核数',
                    hintText: '例如 1.5，留空不限制',
                    isDense: true,
                  ),
                ),
                TextField(
                  controller: _memory,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '内存上限（MB）',
                    hintText: '例如 512，留空不限制',
                    isDense: true,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            FormRow(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _restart,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: '重启策略',
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(value: 'no', child: Text('不自动重启')),
                    DropdownMenuItem(
                      value: 'always',
                      child: Text('始终重启'),
                    ),
                    DropdownMenuItem(
                      value: 'unless-stopped',
                      child: Text('除非手动停止'),
                    ),
                    DropdownMenuItem(
                      value: 'on-failure',
                      child: Text('失败时重启'),
                    ),
                  ],
                  onChanged: (value) =>
                      setState(() => _restart = value ?? 'no'),
                ),
                TextField(
                  controller: _restartMax,
                  enabled: _restart == 'on-failure',
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '最大重试次数',
                    hintText: '留空表示不限',
                    isDense: true,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      PanelCard(
        title: '存储映射',
        trailing: Wrap(
          spacing: 4,
          children: [
            TextButton.icon(
              onPressed: () => setState(
                () => _mounts.add(_MountEntry(type: 'bind')),
              ),
              icon: const Icon(Icons.create_new_folder_outlined, size: 15),
              label: const Text('目录'),
            ),
            TextButton.icon(
              onPressed: () => setState(
                () => _mounts.add(_MountEntry(type: 'volume')),
              ),
              icon: const Icon(Icons.save_outlined, size: 15),
              label: const Text('卷'),
            ),
          ],
        ),
        child: _mounts.isEmpty
            ? Text(
                '没有存储映射。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              )
            : Column(
                children: [
                  for (var index = 0; index < _mounts.length; index++)
                    _mountRow(index),
                ],
              ),
      ),
    ]);
  }

  Widget _mountRow(int index) {
    final mount = _mounts[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SegmentedButton<String>(
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                segments: const [
                  ButtonSegment(value: 'bind', label: Text('目录')),
                  ButtonSegment(value: 'volume', label: Text('存储卷')),
                ],
                selected: {mount.type},
                onSelectionChanged: (value) =>
                    setState(() => mount.type = value.first),
              ),
              const Spacer(),
              Text('只读', style: TextStyle(fontSize: 11, color: hampanelMuted)),
              Switch(
                value: mount.readOnly,
                onChanged: (value) => setState(() => mount.readOnly = value),
              ),
              IconButton(
                tooltip: '删除映射',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() {
                  _mounts.removeAt(index).dispose();
                }),
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: mount.source,
                  readOnly: true,
                  decoration: InputDecoration(
                    labelText: mount.type == 'volume' ? '存储卷' : '本地目录',
                    hintText: mount.type == 'volume'
                        ? '选择一个卷'
                        : '/srv/data',
                    isDense: true,
                  ),
                ),
              ),
              IconButton(
                tooltip: '从远程主机选择',
                visualDensity: VisualDensity.compact,
                onPressed: () => _pickMountSource(mount),
                icon: const Icon(Icons.folder_open_outlined, size: 18),
              ),
              const SizedBox(width: 4),
              Expanded(
                flex: 2,
                child: TextField(
                  controller: mount.destination,
                  decoration: const InputDecoration(
                    labelText: '容器路径',
                    hintText: '/data',
                    isDense: true,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickMountSource(_MountEntry mount) async {
    if (mount.type == 'volume') {
      try {
        final json = await _api.getJson('/api/v1/docker/volumes');
        final map = json as Map<String, dynamic>? ?? const {};
        final nodes = ((map['volumes'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(
              (entry) => RemotePickerNode(
                name: entry['name'] as String? ?? '',
                path: entry['name'] as String? ?? '',
                subtitle: entry['mountpoint'] as String? ?? '',
              ),
            )
            .toList();
        if (!mounted) return;
        if (nodes.isEmpty) {
          _toast('还没有存储卷，请先在存储卷页面创建');
          return;
        }
        final picked = await showRemotePicker(
          context,
          source: TreePickerSource(title: '选择存储卷', nodes: nodes),
          confirmLabel: '使用该卷',
        );
        if (picked != null && mounted) {
          setState(() => mount.source.text = picked);
        }
      } catch (error) {
        _toast(describeError(error));
      }
      return;
    }
    final picked = await showRemotePicker(
      context,
      source: HostDirectorySource(_api),
      initialPath: mount.source.text,
      confirmLabel: '使用该目录',
    );
    if (picked != null && mounted) {
      setState(() => mount.source.text = picked);
    }
  }

  Widget _hostsTab() {
    return _tabList([
      PanelCard(
        title: '主机映射',
        trailing: TextButton.icon(
          onPressed: () async {
            final value = await _hostMappingDialog();
            if (value != null && mounted) setState(() => _addHosts.add(value));
          },
          icon: const Icon(Icons.add, size: 15),
          label: const Text('添加'),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '把 IP 映射成主机名，等价于 docker run --add-host。',
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
            const SizedBox(height: 10),
            if (_addHosts.isEmpty)
              Text(
                '没有自定义主机映射。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              )
            else
              Column(
                children: [
                  for (var index = 0; index < _addHosts.length; index++)
                    _editableRow(
                      label: _addHosts[index],
                      onEdit: () async {
                        final value = await _hostMappingDialog(
                          initial: _addHosts[index],
                        );
                        if (value != null && mounted) {
                          setState(() => _addHosts[index] = value);
                        }
                      },
                      onRemove: () => setState(() => _addHosts.removeAt(index)),
                    ),
                ],
              ),
          ],
        ),
      ),
    ]);
  }

  Widget _startupTab() {
    return _tabList([
      PanelCard(
        title: '启动命令',
        child: Column(
          children: [
            TextField(
              controller: _entrypoint,
              decoration: const InputDecoration(
                labelText: '入口点（entrypoint）',
                hintText: '留空使用镜像默认入口点',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _command,
              minLines: 1,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: '执行命令（command）',
                hintText: 'sh -c "echo hello"',
                isDense: true,
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _user,
              decoration: const InputDecoration(
                labelText: '运行用户',
                hintText: '用户名、UID 或 user:group',
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 12),
      PanelCard(
        title: '运行模式',
        child: Column(
          children: [
            _switchRow(
              title: '分配伪终端（-t）',
              subtitle: '为容器分配 TTY，交互式 shell 需要开启。',
              value: _tty,
              onChanged: (value) => setState(() => _tty = value),
            ),
            _switchRow(
              title: '保持标准输入（-i）',
              subtitle: '即使没有附加也保持 STDIN 打开。',
              value: _stdinOpen,
              onChanged: (value) => setState(() => _stdinOpen = value),
            ),
            _switchRow(
              title: '特权模式（--privileged）',
              subtitle: '容器获得全部设备访问权限，会削弱隔离，谨慎开启。',
              value: _privileged,
              onChanged: (value) => setState(() => _privileged = value),
            ),
          ],
        ),
      ),
    ]);
  }

  Widget _switchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      title: Text(title, style: const TextStyle(fontSize: 12.5)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 11, color: hampanelMuted),
      ),
      value: value,
      onChanged: onChanged,
    );
  }

  Widget _envTab() {
    return _tabList([
      PanelCard(
        title: '环境变量',
        trailing: TextButton.icon(
          onPressed: () async {
            final value = await _keyValueDialog('添加环境变量');
            if (value != null) setState(() => _env.add(value));
          },
          icon: const Icon(Icons.add, size: 15),
          label: const Text('添加'),
        ),
        child: _env.isEmpty
            ? Text(
                '没有环境变量。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              )
            : Column(
                children: [
                  for (var index = 0; index < _env.length; index++)
                    _keyValueRow(
                      value: _env[index],
                      onEdit: () async {
                        final changed = await _keyValueDialog(
                          '编辑环境变量',
                          initial: _env[index],
                        );
                        if (changed != null) {
                          setState(() => _env[index] = changed);
                        }
                      },
                      onRemove: () => setState(() => _env.removeAt(index)),
                    ),
                ],
              ),
      ),
      const SizedBox(height: 12),
      PanelCard(
        title: '标签',
        trailing: TextButton.icon(
          onPressed: () async {
            final value = await _keyValueDialog('添加标签');
            if (value != null && mounted) setState(() => _labels.add(value));
          },
          icon: const Icon(Icons.add, size: 15),
          label: const Text('添加'),
        ),
        child: _labels.isEmpty
            ? Text(
                '没有容器标签。',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              )
            : Column(
                children: [
                  for (var index = 0; index < _labels.length; index++)
                    _keyValueRow(
                      value: _labels[index],
                      onEdit: () async {
                        final value = await _keyValueDialog(
                          '编辑标签',
                          initial: _labels[index],
                        );
                        if (value != null && mounted) {
                          setState(() => _labels[index] = value);
                        }
                      },
                      onRemove: () => setState(() => _labels.removeAt(index)),
                    ),
                ],
              ),
      ),
    ]);
  }

  Widget _editableRow({
    required String label,
    required VoidCallback onEdit,
    required VoidCallback onRemove,
  }) => InkWell(
    onTap: onEdit,
    child: Row(
      children: [
        Expanded(child: Text(label, style: monospace.copyWith(fontSize: 11.5))),
        IconButton(
          tooltip: '删除',
          visualDensity: VisualDensity.compact,
          onPressed: onRemove,
          icon: const Icon(Icons.close, size: 15),
        ),
      ],
    ),
  );

  Widget _keyValueRow({
    required String value,
    required Future<void> Function() onEdit,
    required VoidCallback onRemove,
  }) {
    final split = value.indexOf('=');
    final key = split < 0 ? value : value.substring(0, split);
    final val = split < 0 ? '' : value.substring(split + 1);
    return InkWell(
      onTap: onEdit,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Expanded(
              flex: 2,
              child: Text(
                key,
                style: monospace.copyWith(fontSize: 11.5),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Expanded(
              flex: 3,
              child: Text(
                val,
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              tooltip: '删除',
              visualDensity: VisualDensity.compact,
              onPressed: onRemove,
              icon: const Icon(Icons.close, size: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _readonlyRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace.copyWith(fontSize: 11.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stringChips({
    required List<String> values,
    required String emptyText,
    required String hint,
    required VoidCallback onAdd,
    required ValueChanged<int> onRemove,
  }) {
    if (values.isEmpty) {
      return Row(
        children: [
          Expanded(
            child: Text(
              emptyText,
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 15),
            label: const Text('添加'),
          ),
        ],
      );
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (var index = 0; index < values.length; index++)
          Chip(
            label: Text(
              values[index],
              style: const TextStyle(fontSize: 11.5),
            ),
            onDeleted: () => onRemove(index),
          ),
        TextButton.icon(
          onPressed: onAdd,
          icon: const Icon(Icons.add, size: 15),
          label: Text(hint),
        ),
      ],
    );
  }

  Future<String?> _input(String title, String label) {
    return textInputDialog(context, title: title, label: label);
  }

  Future<String?> _keyValueDialog(String title, {String? initial}) {
    return _pairDialog(title, '名称', '值', '=', initial: initial);
  }

  Future<String?> _hostMappingDialog({String? initial}) {
    return _pairDialog(
      initial == null ? '添加主机映射' : '编辑主机映射',
      '主机名',
      'IP 地址',
      ':',
      initial: initial,
      requireValue: true,
    );
  }

  Future<String?> _pairDialog(
    String title,
    String firstLabel,
    String secondLabel,
    String separator, {
    String? initial,
    bool requireValue = false,
  }) {
    final entry = initial ?? '';
    final equals = entry.indexOf('=');
    final split = equals >= 0 ? equals : entry.indexOf(separator);
    var first = split < 0 ? entry : entry.substring(0, split);
    var second = split < 0 ? '' : entry.substring(split + 1);
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: Text(title),
        content: DialogBody(
          maxWidth: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                initialValue: first,
                onChanged: (value) => first = value,
                decoration: InputDecoration(labelText: firstLabel),
              ),
              const SizedBox(height: 10),
              TextFormField(
                initialValue: second,
                onChanged: (value) => second = value,
                decoration: InputDecoration(labelText: secondLabel),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final key = first.trim();
              final value = requireValue ? second.trim() : second;
              if (key.isEmpty || key.contains(separator) ||
                  (requireValue && InternetAddress.tryParse(value) == null)) {
                return;
              }
              Navigator.of(context).pop('$key$separator$value');
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}

class _MountEntry {
  _MountEntry({
    this.type = 'bind',
    String source = '',
    String destination = '',
    this.readOnly = false,
  }) : source = TextEditingController(text: source),
       destination = TextEditingController(text: destination);

  String type;
  final TextEditingController source;
  final TextEditingController destination;
  bool readOnly;

  String? get spec {
    final from = source.text.trim();
    final to = destination.text.trim();
    if (from.isEmpty || to.isEmpty) return null;
    return '$from:$to${readOnly ? ':ro' : ''}';
  }

  void dispose() {
    source.dispose();
    destination.dispose();
  }
}

List<String> _splitCommand(String value) {
  final result = <String>[];
  final buffer = StringBuffer();
  String? quote;
  for (var index = 0; index < value.length; index++) {
    final char = value[index];
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        buffer.write(char);
      }
      continue;
    }
    if (char == '"' || char == "'") {
      quote = char;
      continue;
    }
    if (char.trim().isEmpty) {
      if (buffer.isNotEmpty) {
        result.add(buffer.toString());
        buffer.clear();
      }
      continue;
    }
    buffer.write(char);
  }
  if (buffer.isNotEmpty) result.add(buffer.toString());
  return result;
}
