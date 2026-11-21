import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

/// SELinux policy management.
///
/// The host is probed first: a machine running AppArmor has no SELinux
/// filesystem, so the page explains that instead of showing controls that could
/// never take effect. When SELinux is present the policy is split into tabs —
/// mode, booleans, file contexts, port labels and denials — because a flat list
/// of hundreds of booleans is unusable.
class SelinuxPage extends StatefulWidget {
  const SelinuxPage({super.key});

  @override
  State<SelinuxPage> createState() => _SelinuxPageState();
}

class _SelinuxPageState extends State<SelinuxPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 5, vsync: this);
  Map<String, dynamic>? _status;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  String _filter = '';

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/security/selinux');
      if (!mounted) return;
      setState(() {
        _status = json as Map<String, dynamic>? ?? const {};
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

  /// Relabel is a task, not a request: minutes on a real root.
  Future<void> _initialize() async {
    setState(() => _busy = true);
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'selinux.initialize',
        title: '初始化 SELinux 面板保护',
      );
      if (!mounted) return;
      showAppSnackBar(context, SnackBar(content: Text('已提交任务：${task.title}')));
      unawaited(center.waitFor(task.id).then((_) {
        if (mounted) _load();
      }));
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(context, SnackBar(content: Text(describeError(error))));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _post(String path, Map<String, Object?> body) async {
    setState(() => _busy = true);
    try {
      final json = await _api.postJson(path, body);
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text(map['output'] as String? ?? '已应用')),
      );
      await _load();
    } catch (error) {
      if (!mounted) return;
      showAppSnackBar(
        context,
        SnackBar(content: Text(describeError(error))),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _editContext({Map<String, dynamic>? current}) async {
    final path = TextEditingController(text: current?['path'] as String? ?? '');
    final type = TextEditingController(text: current?['kind'] as String? ?? '');
    var fileType = current?['file_type'] as String? ?? 'all files';
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: Text(current == null ? '添加文件上下文' : '编辑文件上下文'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '路径可使用正则，例如 /var/www(/.*)?。保存后会执行 restorecon -R '
                  '重打标签。编辑已有规则时先删除再添加。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: path,
                  decoration: const InputDecoration(labelText: '路径表达式'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: type,
                  decoration: const InputDecoration(
                    labelText: 'SELinux 类型',
                    hintText: 'httpd_sys_content_t',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: fileType,
                  decoration: const InputDecoration(labelText: '对象类别'),
                  items: const [
                    DropdownMenuItem(value: 'all files', child: Text('all files')),
                    DropdownMenuItem(value: 'regular file', child: Text('regular file')),
                    DropdownMenuItem(value: 'directory', child: Text('directory')),
                  ],
                  onChanged: (value) => setLocal(() => fileType = value ?? 'all files'),
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
              onPressed: () => Navigator.of(context).pop({
                'path': path.text.trim(),
                'kind': type.text.trim(),
                'file_type': fileType,
              }),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    path.dispose();
    type.dispose();
    if (result == null || !mounted) return;
    if (current != null) {
      await _post('/api/v1/security/selinux/context', {
        ...result,
        'remove': true,
      });
      if (!mounted) return;
    }
    await _post('/api/v1/security/selinux/context', {
      ...result,
      'remove': false,
    });
  }

  Future<void> _editPort() async {
    final port = TextEditingController();
    final type = TextEditingController();
    var protocol = 'tcp';
    final result = await showDialog<Map<String, Object>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('添加端口标签'),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '把端口绑定到 SELinux 类型，例如 http_port_t。未绑定的端口会被'
                  '服务进程拒绝绑定。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: port,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '端口'),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: type,
                  decoration: const InputDecoration(
                    labelText: 'SELinux 类型',
                    hintText: 'http_port_t',
                  ),
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: protocol,
                  decoration: const InputDecoration(labelText: '协议'),
                  items: const [
                    DropdownMenuItem(value: 'tcp', child: Text('tcp')),
                    DropdownMenuItem(value: 'udp', child: Text('udp')),
                    DropdownMenuItem(value: 'sctp', child: Text('sctp')),
                    DropdownMenuItem(value: 'dccp', child: Text('dccp')),
                  ],
                  onChanged: (value) => setLocal(() => protocol = value ?? 'tcp'),
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
              onPressed: () => Navigator.of(context).pop({
                'port': int.tryParse(port.text.trim()) ?? 0,
                'protocol': protocol,
                'kind': type.text.trim(),
                'remove': false,
              }),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    port.dispose();
    type.dispose();
    if (result == null || !mounted) return;
    await _post('/api/v1/security/selinux/port', result);
  }

  bool _matches(String value) {
    if (_filter.isEmpty) return true;
    return value.toLowerCase().contains(_filter.toLowerCase());
  }

  @override
  Widget build(BuildContext context) {
    final status = _status ?? const <String, dynamic>{};
    final present = status['present'] == true;
    final tooling = status['tooling'] == true;
    final semanage = status['semanage'] == true;
    final enforcing = status['enforcing'] as bool?;

    final booleans = ((status['booleans'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((entry) => _matches(entry['name'] as String? ?? ''))
        .toList();
    final contexts = ((status['contexts'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((entry) =>
            _matches(entry['path'] as String? ?? '') ||
            _matches(entry['kind'] as String? ?? ''))
        .toList();
    final ports = ((status['ports'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .where((entry) => _matches(entry['kind'] as String? ?? ''))
        .toList();
    final denials = ((status['denials'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final modules = ((status['modules'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();

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
          : present
          ? Column(
              children: [
                TabBar(
                  controller: _tabs,
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  tabs: [
                    const Tab(text: '概览'),
                    Tab(text: '布尔开关 (${booleans.length})'),
                    Tab(text: '文件上下文 (${contexts.length})'),
                    Tab(text: '端口标签 (${ports.length})'),
                    Tab(text: '拒绝日志 (${denials.length})'),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: TextField(
                    decoration: const InputDecoration(
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 18),
                      hintText: '筛选名称、路径或类型',
                    ),
                    onChanged: (value) => setState(() => _filter = value),
                  ),
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabs,
                    children: [
                      _overview(status, enforcing, tooling, semanage, modules),
                      _booleansTab(booleans, tooling),
                      _contextsTab(contexts, semanage),
                      _portsTab(ports, semanage),
                      _denialsTab(denials),
                    ],
                  ),
                ),
              ],
            )
          : ListView(
              padding: pageContentPadding(context),
              children: [
                PanelCard(
                  title: '本机未启用 SELinux',
                  trailing: const StatusPill(text: '未启用', good: false),
                  child: Text(
                    status['message'] as String? ?? '',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: '开机配置',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _row(
                        'SELINUX=',
                        (status['configured'] as String?)?.isNotEmpty == true
                            ? status['configured'] as String
                            : '—',
                      ),
                      _row(
                        'SELINUXTYPE=',
                        (status['policy'] as String?)?.isNotEmpty == true
                            ? status['policy'] as String
                            : '—',
                      ),
                      _row('管理工具', tooling || semanage ? '已安装' : '未安装'),
                      const SizedBox(height: 8),
                      Text(
                        '启用 SELinux 需要内核启动参数与策略包，属于需要重启的改动，'
                        '不在面板内自动执行。',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: hampanelMuted,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _overview(
    Map<String, dynamic> status,
    bool? enforcing,
    bool tooling,
    bool semanage,
    List<Map<String, dynamic>> modules,
  ) {
    final relabelled = status['relabelled'] == true;
    final managedPaths = (status['managed_paths'] as num?)?.toInt() ?? 0;
    final totalPaths = (status['managed_total'] as num?)?.toInt() ?? 0;

    return ListView(
      padding: pageContentPadding(context),
      children: [
        // Entering enforcing on a host that was never relabelled is how
        // machines stop booting: init stays unlabeled_t, every process falls
        // back to kernel_t, and the policy then denies boot-time access. So the
        // initialization is an explicit, visible step rather than something
        // hidden behind the mode buttons.
        PanelCard(
          title: '面板初始化',
          trailing: StatusPill(
            text: relabelled ? '已完成' : '未完成',
            good: relabelled,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                relabelled
                    ? '面板路径与容器存储已完成权限标注，可以安全切换 enforcing。'
                    : '尚未完成权限标注。在未初始化的主机上切换到 enforcing，'
                          '可能因为进程停留在 kernel_t 而无法启动。',
                style: TextStyle(
                  fontSize: 11.5,
                  color: relabelled ? hampanelMuted : hampanelDanger,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 8),
              _row('受管路径规则', '$managedPaths 条'),
              if (totalPaths > 0) _row('应覆盖路径', '$totalPaths 条'),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _initialize,
                  icon: const Icon(Icons.security_outlined, size: 16),
                  label: Text(relabelled ? '重新初始化' : '初始化面板保护'),
                ),
              ),
              const SizedBox(height: 6),
              Text(
                '会为面板自身路径（配置、数据、日志、unit）与容器存储写入规则，'
                '并跳过容器存储做一次重打标签。在大型磁盘上需要数分钟。',
                style: TextStyle(fontSize: 11, color: hampanelMuted, height: 1.5),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PanelCard(
          title: '运行模式',
          trailing: StatusPill(
            text: enforcing == true ? 'enforcing' : 'permissive',
            good: enforcing == true,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row('当前', enforcing == true ? 'enforcing' : 'permissive'),
              _row(
                '开机配置',
                (status['configured'] as String?)?.isNotEmpty == true
                    ? status['configured'] as String
                    : '—',
              ),
              _row(
                '策略类型',
                (status['policy'] as String?)?.isNotEmpty == true
                    ? status['policy'] as String
                    : '—',
              ),
              _row('策略模块', '${modules.length} 个'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final mode in const ['enforcing', 'permissive', 'disabled'])
                    OutlinedButton(
                      // enforcing is only offered once the relabel marker
                      // exists; the backend refuses it anyway (409
                      // RelabelRequired), so the UI must not pretend otherwise.
                      onPressed: _busy ||
                              !tooling ||
                              (mode == 'enforcing' && !relabelled)
                          ? null
                          : () => _post('/api/v1/security/selinux/mode', {'mode': mode}),
                      child: Text(mode),
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'enforcing / permissive 立即生效；disabled 只写配置，需要重启主机。',
                style: TextStyle(
                  fontSize: 11.5,
                  color: hampanelMuted,
                  height: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PanelCard(
          title: '策略模块',
          trailing: Text(
            '${modules.length} 个',
            style: TextStyle(fontSize: 11, color: hampanelMuted),
          ),
          child: modules.isEmpty
              ? Text(
                  '没有可读的模块列表。',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final module in modules.take(30))
                      Padding(
                        padding: const EdgeInsets.only(bottom: 4),
                        child: Text(
                          '${module['name']} ${module['version']}'.trim(),
                          style: monospace.copyWith(fontSize: 11),
                        ),
                      ),
                  ],
                ),
        ),
        if (!semanage) ...[
          const SizedBox(height: 12),
          PanelCard(
            title: '缺少 semanage',
            child: Text(
              '未安装 semanage，无法查看或编辑文件上下文与端口标签。',
              style: TextStyle(
                fontSize: 11.5,
                color: hampanelMuted,
                height: 1.5,
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _booleansTab(List<Map<String, dynamic>> booleans, bool tooling) {
    if (booleans.isEmpty) return _empty('没有匹配的布尔开关。');
    return ListView.builder(
      padding: pageContentPadding(context),
      itemCount: booleans.length,
      itemBuilder: (context, index) {
        final entry = booleans[index];
        final name = entry['name'] as String? ?? '';
        return SwitchListTile(
          dense: true,
          title: Text(name, style: monospace.copyWith(fontSize: 11.5)),
          value: entry['enabled'] == true,
          onChanged: _busy || !tooling
              ? null
              : (value) => _post('/api/v1/security/selinux/boolean', {
                  'name': name,
                  'enabled': value,
                }),
        );
      },
    );
  }

  Widget _contextsTab(List<Map<String, dynamic>> contexts, bool semanage) {
    return ListView(
      padding: pageContentPadding(context),
      children: [
        PanelCard(
          title: '文件上下文',
          trailing: semanage
              ? TextButton.icon(
                  onPressed: _busy ? null : () => _editContext(),
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                )
              : null,
          child: contexts.isEmpty
              ? Text(
                  '没有本地文件上下文定制。',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                )
              : Column(
                  children: [
                    for (final entry in contexts)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    entry['path'] as String? ?? '',
                                    style: monospace.copyWith(fontSize: 11.5),
                                  ),
                                  Text(
                                    '${entry['kind']} · ${entry['file_type']}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hampanelMuted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (semanage)
                              IconButton(
                                tooltip: '删除并重打标签',
                                onPressed: _busy
                                    ? null
                                    : () => _post(
                                        '/api/v1/security/selinux/context',
                                        {...entry, 'remove': true},
                                      ),
                                icon: const Icon(Icons.delete_outline, size: 18),
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

  Widget _portsTab(List<Map<String, dynamic>> ports, bool semanage) {
    return ListView(
      padding: pageContentPadding(context),
      children: [
        PanelCard(
          title: '端口标签',
          trailing: semanage
              ? TextButton.icon(
                  onPressed: _busy ? null : _editPort,
                  icon: const Icon(Icons.add, size: 16),
                  label: const Text('添加'),
                )
              : null,
          child: ports.isEmpty
              ? Text(
                  '没有端口类型定义。',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                )
              : Column(
                  children: [
                    for (final entry in ports)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${entry['port']}/${entry['protocol']}',
                                style: monospace.copyWith(fontSize: 11.5),
                              ),
                            ),
                            Text(
                              entry['kind'] as String? ?? '',
                              style: monospace.copyWith(
                                fontSize: 11,
                                color: hampanelMuted,
                              ),
                            ),
                            if (semanage)
                              IconButton(
                                onPressed: _busy
                                    ? null
                                    : () => _post(
                                        '/api/v1/security/selinux/port',
                                        {...entry, 'remove': true},
                                      ),
                                icon: const Icon(Icons.delete_outline, size: 18),
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

  Widget _denialsTab(List<Map<String, dynamic>> denials) {
    if (denials.isEmpty) {
      return _empty(
        '最近没有 AVC 拒绝记录。若刚修改了策略，可在此确认是否仍有阻挡。',
      );
    }
    return ListView.builder(
      padding: pageContentPadding(context),
      itemCount: denials.length,
      itemBuilder: (context, index) {
        final entry = denials[index];
        return PanelCard(
          title: '${entry['permission']} · ${entry['tclass']}',
          trailing: Text(
            entry['at'] as String? ?? '',
            style: TextStyle(fontSize: 10, color: hampanelMuted),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if ((entry['path'] as String?)?.isNotEmpty == true)
                Text(
                  entry['path'] as String,
                  style: monospace.copyWith(fontSize: 11.5),
                ),
              Text(
                'scontext: ${entry['source']}',
                style: monospace.copyWith(fontSize: 11, color: hampanelMuted),
              ),
              Text(
                'tcontext: ${entry['target']}',
                style: monospace.copyWith(fontSize: 11, color: hampanelMuted),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _empty(String text) => ListView(
    padding: pageContentPadding(context),
    children: [
      Text(
        text,
        style: TextStyle(fontSize: 11.5, color: hampanelMuted, height: 1.6),
      ),
    ],
  );

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}
