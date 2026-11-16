import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class RegistriesSection extends StatefulWidget {
  const RegistriesSection({super.key});

  @override
  State<RegistriesSection> createState() => _RegistriesSectionState();
}

class _RegistriesSectionState extends State<RegistriesSection> {
  List<DockerRegistry> _registries = const [];
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
      final json = await _api.getJson('/api/v1/docker/registries');
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      setState(() {
        _registries = ((map['registries'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerRegistry.fromJson)
            .toList();
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

  Future<void> _edit([DockerRegistry? registry]) async {
    final saved = await showDialog<bool>(
      context: context,
      builder: (context) => _RegistryDialog(registry: registry),
    );
    if (saved == true) {
      _toast(registry == null ? '镜像源已添加' : '镜像源已更新');
      await _load();
    }
  }

  Future<void> _sync(DockerRegistry registry) async {
    try {
      final json = await _api.postJson(
        '/api/v1/docker/registries/${registry.id}/sync',
        const <String, dynamic>{},
        timeout: const Duration(minutes: 2),
      );
      final map = json as Map<String, dynamic>? ?? const {};
      _toast(
        map['ok'] == true
            ? '${registry.name} 登录成功'
            : (map['output'] as String? ?? '${registry.name} 登录失败'),
      );
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _delete(DockerRegistry registry) async {
    final ok = await confirmDialog(
      context,
      title: '删除镜像源 ${registry.name}?',
      message: '只会删除 hampanel 保存的登录信息，不会退出 Docker 当前登录。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      await _api.deleteJson('/api/v1/docker/registries/${registry.id}');
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '源管理',
          subtitle: '${_registries.length} 个 Docker / Podman 镜像源',
          actions: [
            FilledButton.icon(
              onPressed: () => _edit(),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加镜像源'),
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
              : _registries.isEmpty
              ? EmptyState(
                  icon: Icons.dns_outlined,
                  title: '没有镜像源',
                  message: '添加私有仓库或镜像加速源的登录信息，供拉取、推送和检索使用。',
                  action: FilledButton.icon(
                    onPressed: () => _edit(),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加镜像源'),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
                  itemCount: _registries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 10),
                  itemBuilder: (context, index) {
                    final registry = _registries[index];
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Row(
                          children: [
                            Icon(
                              Icons.dns_outlined,
                              size: 20,
                              color: registry.lastSyncOk == true
                                  ? hampanelAccent
                                  : hampanelMuted,
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        registry.name,
                                        style: const TextStyle(
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Text(
                                        registry.engine,
                                        style: TextStyle(
                                          fontSize: 10,
                                          color: hampanelMuted,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    '${registry.address}'
                                    '${registry.username.isEmpty ? '' : ' · ${registry.username}'}'
                                    '${registry.hasSecret ? ' · 已保存密码' : ''}',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hampanelMuted,
                                    ),
                                  ),
                                  if (registry.lastSyncMessage.isNotEmpty)
                                    Text(
                                      registry.lastSyncMessage,
                                      maxLines: 2,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 10.5,
                                        color: hampanelDanger,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (registry.lastSyncOk != null)
                              StatusPill(
                                text: registry.lastSyncOk! ? '已同步' : '同步失败',
                                good: registry.lastSyncOk!,
                              ),
                            const SizedBox(width: 6),
                            IconButton(
                              tooltip: '同步登录',
                              onPressed: () => _sync(registry),
                              icon: const Icon(Icons.sync, size: 17),
                            ),
                            PopupMenuButton<String>(
                              icon: const Icon(Icons.more_horiz, size: 18),
                              onSelected: (value) {
                                if (value == 'edit') _edit(registry);
                                if (value == 'delete') _delete(registry);
                              },
                              itemBuilder: (context) => const [
                                PopupMenuItem(value: 'edit', child: Text('编辑')),
                                PopupMenuItem(value: 'delete', child: Text('删除')),
                              ],
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _RegistryDialog extends StatefulWidget {
  const _RegistryDialog({this.registry});

  final DockerRegistry? registry;

  @override
  State<_RegistryDialog> createState() => _RegistryDialogState();
}

class _RegistryDialogState extends State<_RegistryDialog> {
  late final TextEditingController _name;
  late final TextEditingController _host;
  late final TextEditingController _username;
  late final TextEditingController _secret;
  String _engine = 'docker';
  String _protocol = 'https';
  bool _saving = false;
  String? _error;

  bool get _editing => widget.registry != null;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    final registry = widget.registry;
    _name = TextEditingController(text: registry?.name ?? '');
    _host = TextEditingController(text: registry?.host ?? '');
    _username = TextEditingController(text: registry?.username ?? '');
    _secret = TextEditingController();
    _engine = registry?.engine ?? 'docker';
    _protocol = registry?.protocol ?? 'https';
  }

  @override
  void dispose() {
    _name.dispose();
    _host.dispose();
    _username.dispose();
    _secret.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _host.text.trim().isEmpty) {
      setState(() => _error = '名称和地址不能为空');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final body = <String, dynamic>{
      'engine': _engine,
      'name': _name.text.trim(),
      'protocol': _protocol,
      'host': _host.text.trim(),
      'username': _username.text.trim(),
      'secret': _secret.text,
    };
    try {
      if (_editing) {
        await _api.putJson(
          '/api/v1/docker/registries/${widget.registry!.id}',
          body,
        );
      } else {
        await _api.postJson('/api/v1/docker/registries', body);
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _saving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(_editing ? '编辑镜像源' : '添加镜像源'),
      content: DialogBody(
        maxWidth: 520,
        child: SingleChildScrollView(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _engine,
                      decoration: const InputDecoration(labelText: '引擎'),
                      items: const [
                        DropdownMenuItem(value: 'docker', child: Text('Docker')),
                        DropdownMenuItem(value: 'podman', child: Text('Podman')),
                        DropdownMenuItem(
                          value: 'both',
                          child: Text('Docker + Podman'),
                        ),
                      ],
                      onChanged: (value) =>
                          setState(() => _engine = value ?? 'docker'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _protocol,
                      decoration: const InputDecoration(labelText: '协议'),
                      items: const [
                        DropdownMenuItem(value: 'https', child: Text('https')),
                        DropdownMenuItem(value: 'http', child: Text('http')),
                      ],
                      onChanged: (value) =>
                          setState(() => _protocol = value ?? 'https'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: '名称',
                  hintText: '公司私有仓库',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _host,
                decoration: const InputDecoration(
                  labelText: '主机 / 地址',
                  hintText: 'registry.example.com',
                ),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _username,
                decoration: const InputDecoration(labelText: '用户名'),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _secret,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: _editing ? '密码（留空保持不变）' : '密码',
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 12, color: hampanelDanger),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
