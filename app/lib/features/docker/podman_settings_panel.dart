import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/file_entry.dart';
import '../../ui/collapsible.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class PodmanSettingsPanel extends StatefulWidget {
  const PodmanSettingsPanel({super.key, required this.api});

  final ApiClient api;

  @override
  State<PodmanSettingsPanel> createState() => _PodmanSettingsPanelState();
}

class _PodmanSettingsPanelState extends State<PodmanSettingsPanel> {
  static const _containersPath = '/etc/containers/containers.conf';
  static const _containersDropIn =
      '/etc/containers/containers.conf.d/99-hampanel.conf';
  static const _registriesPath = '/etc/containers/registries.conf';
  static const _registriesDropIn =
      '/etc/containers/registries.conf.d/99-hampanel.conf';
  static const _storagePath = '/etc/containers/storage.conf';

  final _text = <String, TextEditingController>{};
  final _select = <String, String>{};
  final _flags = <String, bool>{};
  final _open = <String>{'镜像与仓库', '引擎', '容器默认值'};

  bool _loading = true;
  bool _saving = false;
  bool _loaded = false;
  bool _restarting = false;
  String? _error;

  TextEditingController _c(String key) =>
      _text.putIfAbsent(key, TextEditingController.new);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final controller in _text.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loaded = false;
      _error = null;
    });
    try {
      final containers = <String, String>{
        ..._parseToml(await _read(_containersPath)),
        ..._parseToml(await _read(_containersDropIn)),
      };
      final registriesBase = await _read(_registriesPath);
      final registriesDrop = await _read(_registriesDropIn);
      final registries = <String, String>{
        ..._parseToml(registriesBase),
        ..._parseToml(registriesDrop),
      };
      final storage = _parseToml(await _read(_storagePath));
      if (!mounted) return;

      _fillSelect(containers, 'engine.cgroup_manager', 'systemd');
      _fillSelect(containers, 'engine.events_logger', 'journald');
      _fillText(containers, 'engine.runtime', '');
      _fillText(containers, 'engine.stop_timeout', '10');
      _fillText(containers, 'engine.service_timeout', '5');
      _fillList(
        containers,
        'engine.compose_providers',
        'podman-compose\ndocker-compose',
      );
      _fillText(containers, 'engine.image_copy_tmp_dir', '/var/tmp');
      _flags['engine.compose_warning_logs'] = _boolValue(
        containers,
        'engine.compose_warning_logs',
        false,
      );

      _fillText(containers, 'containers.pids_limit', '2048');
      _fillText(containers, 'containers.shm_size', '65536k');
      _fillSelect(containers, 'containers.log_driver', 'k8s-file');
      _fillText(containers, 'containers.log_size', '10mb');
      _fillText(containers, 'containers.tz', '');
      _fillSelect(containers, 'containers.userns', 'host');
      _fillList(
        containers,
        'containers.default_capabilities',
        'CAP_CHOWN\nCAP_DAC_OVERRIDE\nCAP_FOWNER\nCAP_FSETID\nCAP_KILL\n'
            'CAP_NET_BIND_SERVICE\nCAP_SETFCAP\nCAP_SETGID\nCAP_SETPCAP\n'
            'CAP_SETUID\nCAP_SYS_CHROOT',
      );
      _fillList(containers, 'containers.default_sysctls', '');
      _fillList(containers, 'containers.dns_servers', '');
      _fillList(containers, 'containers.env', '');
      _flags['containers.init'] = _boolValue(
        containers,
        'containers.init',
        false,
      );
      _flags['containers.read_only'] = _boolValue(
        containers,
        'containers.read_only',
        false,
      );

      _fillText(containers, 'network.default_network', 'podman');
      _fillSelect(containers, 'network.network_backend', 'netavark');
      _fillSelect(containers, 'network.firewall_driver', 'iptables');
      _fillText(containers, 'network.dns_bind_port', '53');
      _fillSelect(
        containers,
        'network.default_rootless_network_cmd',
        'slirp4netns',
      );
      _fillText(containers, 'network.network_config_dir', '');
      _fillList(containers, 'network.pasta_options', '');
      _flags['network.rootless_port_forward'] = _boolValue(
        containers,
        'network.rootless_port_forward',
        false,
      );

      _fillList(
        registries,
        'unqualified-search-registries',
        'docker.io\nquay.io',
      );
      _fillSelect(registries, 'short-name-mode', 'enforcing');
      final registryEntries = _RegistryEntries.merge([
        ..._parseRegistryEntries(registriesBase),
        ..._parseRegistryEntries(registriesDrop),
      ]);
      _fillText(
        {'hampanel.insecure': registryEntries.insecure.join('\n')},
        'hampanel.insecure',
        '',
      );
      _fillText(
        {'hampanel.mirrors': registryEntries.mirrors.join('\n')},
        'hampanel.mirrors',
        '',
      );

      _fillSelect(storage, 'storage.driver', 'overlay');
      _fillText(storage, 'storage.graphroot', '/var/lib/containers/storage');
      _fillText(storage, 'storage.runroot', '/run/containers/storage');
      _fillText(storage, 'storage.rootless_storage_path', '');
      _fillText(containers, 'engine.volume_path', '');
      if (_c('engine.volume_path').text.isEmpty) {
        _c('engine.volume_path').text = _stringValue(
          storage,
          'storage.volume_path',
          '',
        );
      }
      _fillText(storage, 'storage.options.mount_program', '');
      _fillText(storage, 'storage.options.overlay.mountopt', '');
      // Older panel builds wrote these under the storage table; migrate.
      if (_c('storage.options.mount_program').text.isEmpty) {
        _c('storage.options.mount_program').text = _stringValue(
          storage,
          'storage.mount_program',
          '',
        );
      }
      if (_c('storage.options.overlay.mountopt').text.isEmpty) {
        _c('storage.options.overlay.mountopt').text = _stringValue(
          storage,
          'storage.mountopt',
          '',
        );
      }
      _fillText(storage, 'storage.transient_store', '');
      _flags['storage.transient_store'] = _boolValue(
        storage,
        'storage.transient_store',
        false,
      );
      _fillText(storage, 'storage.options.overlay.mount_program', '');
      _fillText(storage, 'storage.options.overlay.size', '');
      _fillText(storage, 'storage.options.overlay.inodes', '');
      _flags['storage.options.overlay.ignore_chown_errors'] = _boolValue(
        storage,
        'storage.options.overlay.ignore_chown_errors',
        false,
      );

      setState(() {
        _loading = false;
        _loaded = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  Future<String> _read(String path) async {
    try {
      final json = await widget.api.getJson(
        '/api/v1/files/content',
        query: {'path': path},
      );
      final map = json as Map<String, dynamic>;
      final content = FileContent.fromJson(map);
      content.requireEditable();
      return content.content;
    } on ApiException catch (error) {
      if (error.status == 404) return '';
      rethrow;
    }
  }

  Future<void> _write(String path, String content) async {
    await widget.api.putJson('/api/v1/files/content', {
      'path': path,
      'content': content,
    });
  }

  Future<void> _ensureDir(String path) async {
    await widget.api.postJson('/api/v1/files/mkdir', {
      'path': path,
      'recursive': true,
    });
  }

  void _fillText(Map<String, String> source, String key, String fallback) {
    _c(key).text = _stringValue(source, key, fallback);
  }

  void _fillList(Map<String, String> source, String key, String fallback) {
    _c(key).text = _listValue(source, key, fallback).join('\n');
  }

  void _fillSelect(Map<String, String> source, String key, String fallback) {
    _select[key] = _stringValue(source, key, fallback);
  }

  Future<void> _save() async {
    if (!_loaded || _loading || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final storage = _patchStorage(await _read(_storagePath));
      await _ensureDir('/etc/containers/containers.conf.d');
      await _ensureDir('/etc/containers/registries.conf.d');
      await _write(_containersDropIn, _renderContainers());
      await _write(_registriesDropIn, _renderRegistries());
      if (storage.trim().isNotEmpty) {
        await _write(_storagePath, storage);
      }
      if (!mounted) return;
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Podman 配置已保存；重启容器管理器后生效'),
          action: SnackBarAction(label: '立即重启', onPressed: _restart),
        ),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _restart() async {
    setState(() => _restarting = true);
    try {
      final json = await widget.api.postJson(
        '/api/v1/docker/restart',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      final output = (map['output'] as String? ?? '').trim();
      _toast(
        map['ok'] == true
            ? (output.isEmpty ? 'Podman 已重启' : output)
            : (output.isEmpty ? 'Podman 重启失败' : output),
      );
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _restarting = false);
    }
  }

  String _renderContainers() {
    final out = StringBuffer()
      ..writeln('# Managed by Hampanel')
      ..writeln('[containers]');
    _tomlList(
      out,
      'default_capabilities',
      _c('containers.default_capabilities').text,
    );
    _tomlList(out, 'default_sysctls', _c('containers.default_sysctls').text);
    _tomlList(out, 'dns_servers', _c('containers.dns_servers').text);
    _tomlList(out, 'env', _c('containers.env').text);
    _tomlNumber(out, 'pids_limit', _c('containers.pids_limit').text.trim());
    _tomlString(out, 'shm_size', _c('containers.shm_size').text.trim());
    _tomlString(
      out,
      'log_driver',
      _select['containers.log_driver'] ?? 'k8s-file',
    );
    _tomlString(out, 'log_size', _c('containers.log_size').text.trim());
    _tomlString(out, 'tz', _c('containers.tz').text.trim());
    _tomlString(out, 'userns', _select['containers.userns'] ?? 'host');
    _tomlBool(out, 'init', _flags['containers.init'] ?? false);
    _tomlBool(out, 'read_only', _flags['containers.read_only'] ?? false);

    out.writeln();
    out.writeln('[engine]');
    _tomlString(
      out,
      'cgroup_manager',
      _select['engine.cgroup_manager'] ?? 'systemd',
    );
    _tomlString(
      out,
      'events_logger',
      _select['engine.events_logger'] ?? 'journald',
    );
    _tomlString(out, 'runtime', _c('engine.runtime').text.trim());
    _tomlNumber(out, 'stop_timeout', _c('engine.stop_timeout').text.trim());
    _tomlNumber(
      out,
      'service_timeout',
      _c('engine.service_timeout').text.trim(),
    );
    _tomlList(out, 'compose_providers', _c('engine.compose_providers').text);
    _tomlString(
      out,
      'image_copy_tmp_dir',
      _c('engine.image_copy_tmp_dir').text.trim(),
    );
    _tomlString(out, 'volume_path', _c('engine.volume_path').text.trim());
    _tomlBool(
      out,
      'compose_warning_logs',
      _flags['engine.compose_warning_logs'] ?? false,
    );

    out.writeln();
    out.writeln('[network]');
    _tomlString(
      out,
      'default_network',
      _c('network.default_network').text.trim(),
    );
    _tomlString(
      out,
      'network_backend',
      _select['network.network_backend'] ?? 'netavark',
    );
    _tomlString(
      out,
      'firewall_driver',
      _select['network.firewall_driver'] ?? 'iptables',
    );
    _tomlNumber(out, 'dns_bind_port', _c('network.dns_bind_port').text.trim());
    _tomlString(
      out,
      'default_rootless_network_cmd',
      _select['network.default_rootless_network_cmd'] ?? 'slirp4netns',
    );
    _tomlString(
      out,
      'network_config_dir',
      _c('network.network_config_dir').text.trim(),
    );
    _tomlList(out, 'pasta_options', _c('network.pasta_options').text);
    _tomlBool(
      out,
      'rootless_port_forward',
      _flags['network.rootless_port_forward'] ?? false,
    );
    return out.toString();
  }

  String _renderRegistries() {
    final out = StringBuffer()..writeln('# Managed by Hampanel');
    _tomlList(
      out,
      'unqualified-search-registries',
      _c('unqualified-search-registries').text,
    );
    _tomlString(
      out,
      'short-name-mode',
      _select['short-name-mode'] ?? 'enforcing',
    );
    for (final registry in _lines(_c('hampanel.insecure').text)) {
      out
        ..writeln()
        ..writeln('[[registry]]')
        ..writeln('prefix = ${_quote(registry)}')
        ..writeln('location = ${_quote(registry)}')
        ..writeln('insecure = true');
    }
    for (final line in _lines(_c('hampanel.mirrors').text)) {
      final index = line.indexOf('=');
      if (index <= 0) continue;
      final source = line.substring(0, index).trim();
      final mirror = line.substring(index + 1).trim();
      if (source.isEmpty || mirror.isEmpty) continue;
      out
        ..writeln()
        ..writeln('[[registry]]')
        ..writeln('prefix = ${_quote(source)}')
        ..writeln('location = ${_quote(source)}')
        ..writeln('[[registry.mirror]]')
        ..writeln('location = ${_quote(mirror)}');
    }
    return out.toString();
  }

  String _patchStorage(String source) => patchPodmanStorageToml(
    source,
    driver: _select['storage.driver'] ?? 'overlay',
    graphroot: _c('storage.graphroot').text.trim(),
    runroot: _c('storage.runroot').text.trim(),
    rootlessStoragePath: _c('storage.rootless_storage_path').text.trim(),
    mountProgram: _c('storage.options.mount_program').text.trim(),
    overlayMountProgram: _c('storage.options.overlay.mount_program').text
        .trim(),
    mountOpt: _c('storage.options.overlay.mountopt').text.trim(),
    overlaySize: _c('storage.options.overlay.size').text.trim(),
    overlayInodes: _c('storage.options.overlay.inodes').text.trim(),
    transientStore: _flags['storage.transient_store'] == true,
    ignoreChownErrors:
        _flags['storage.options.overlay.ignore_chown_errors'] == true,
  );

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const LoadingView();
    return ListView(
      padding: pageContentPadding(context, top: 8),
      children: [
        if (_error != null) ...[
          ErrorBanner(message: _error!, onRetry: _load),
          const SizedBox(height: 10),
        ],
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _saving || !_loaded ? null : _save,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.save_outlined, size: 16),
              label: Text(_saving ? '保存中…' : '保存配置'),
            ),
            OutlinedButton.icon(
              onPressed: _restarting ? null : _restart,
              icon: _restarting
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.restart_alt, size: 16),
              label: Text(_restarting ? '重启中…' : '重启 Podman'),
            ),
            Text(
              '配置写入 containers.conf.d / registries.conf.d 和 storage.conf',
              style: TextStyle(fontSize: 11, color: hampanelMuted),
            ),
          ],
        ),
        const SizedBox(height: 12),
        _group('镜像与仓库', [
          TextField(
            controller: _c('unqualified-search-registries'),
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '未限定镜像的搜索仓库',
              hintText: 'docker.io\nquay.io',
              helperText: '每行一个仓库；影响短名称镜像解析',
            ),
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey(_select['short-name-mode']),
            initialValue: _select['short-name-mode'] ?? 'enforcing',
            decoration: const InputDecoration(labelText: '短名称解析策略'),
            items: const [
              DropdownMenuItem(
                value: 'enforcing',
                child: Text('enforcing（强制确认）'),
              ),
              DropdownMenuItem(
                value: 'permissive',
                child: Text('permissive（自动解析）'),
              ),
              DropdownMenuItem(
                value: 'disabled',
                child: Text('disabled（禁用短名称）'),
              ),
            ],
            onChanged: (value) => setState(
              () => _select['short-name-mode'] = value ?? 'enforcing',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c('hampanel.insecure'),
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '受信任的 HTTP 仓库',
              hintText: 'registry.internal:5000',
              helperText: '每行一个；会写入 registries.conf.d，标记 insecure',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c('hampanel.mirrors'),
            minLines: 2,
            maxLines: 5,
            decoration: const InputDecoration(
              labelText: '仓库镜像（源=镜像）',
              hintText: 'docker.io=https://mirror.example.com',
              helperText: '每行一个；用于 registry.mirror',
            ),
          ),
        ]),
        _group('引擎', [
          FormRow(
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey(_select['engine.cgroup_manager']),
                initialValue: _select['engine.cgroup_manager'] ?? 'systemd',
                decoration: const InputDecoration(labelText: 'Cgroup Manager'),
                items: const [
                  DropdownMenuItem(value: 'systemd', child: Text('systemd')),
                  DropdownMenuItem(value: 'cgroupfs', child: Text('cgroupfs')),
                ],
                onChanged: (value) => setState(
                  () => _select['engine.cgroup_manager'] = value ?? 'systemd',
                ),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(_select['engine.events_logger']),
                initialValue: _select['engine.events_logger'] ?? 'journald',
                decoration: const InputDecoration(labelText: '事件日志'),
                items: const [
                  DropdownMenuItem(value: 'journald', child: Text('journald')),
                  DropdownMenuItem(value: 'file', child: Text('file')),
                  DropdownMenuItem(value: 'none', child: Text('none')),
                ],
                onChanged: (value) => setState(
                  () => _select['engine.events_logger'] = value ?? 'journald',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('engine.runtime'),
                decoration: const InputDecoration(
                  labelText: 'OCI Runtime',
                  hintText: '留空自动选择（crun / runc）',
                ),
              ),
              TextField(
                controller: _c('engine.stop_timeout'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '停止超时（秒）'),
              ),
              TextField(
                controller: _c('engine.service_timeout'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '服务超时（秒）'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c('engine.compose_providers'),
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Compose Provider 顺序',
              helperText: '每行一个；默认优先 podman-compose',
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c('engine.image_copy_tmp_dir'),
            decoration: const InputDecoration(labelText: '镜像复制临时目录'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Compose 警告日志'),
            value: _flags['engine.compose_warning_logs'] ?? false,
            onChanged: (value) =>
                setState(() => _flags['engine.compose_warning_logs'] = value),
          ),
        ]),
        _group('容器默认值', [
          TextField(
            controller: _c('containers.default_capabilities'),
            minLines: 2,
            maxLines: 6,
            decoration: const InputDecoration(
              labelText: '默认 Capabilities',
              helperText: '每行一个，例如 CAP_NET_ADMIN',
            ),
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('containers.pids_limit'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'PID 上限'),
              ),
              TextField(
                controller: _c('containers.shm_size'),
                decoration: const InputDecoration(
                  labelText: '共享内存大小',
                  hintText: '65536k',
                ),
              ),
              TextField(
                controller: _c('containers.log_size'),
                decoration: const InputDecoration(
                  labelText: '日志大小上限',
                  hintText: '10mb',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey(_select['containers.log_driver']),
                initialValue: _select['containers.log_driver'] ?? 'k8s-file',
                decoration: const InputDecoration(labelText: '容器日志驱动'),
                items: const [
                  DropdownMenuItem(value: 'k8s-file', child: Text('k8s-file')),
                  DropdownMenuItem(value: 'journald', child: Text('journald')),
                  DropdownMenuItem(value: 'none', child: Text('none')),
                ],
                onChanged: (value) => setState(
                  () => _select['containers.log_driver'] = value ?? 'k8s-file',
                ),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(_select['containers.userns']),
                initialValue: _select['containers.userns'] ?? 'host',
                decoration: const InputDecoration(labelText: 'User Namespace'),
                items: const [
                  DropdownMenuItem(value: 'host', child: Text('host')),
                  DropdownMenuItem(value: 'keep-id', child: Text('keep-id')),
                  DropdownMenuItem(value: 'auto', child: Text('auto')),
                ],
                onChanged: (value) => setState(
                  () => _select['containers.userns'] = value ?? 'host',
                ),
              ),
              TextField(
                controller: _c('containers.tz'),
                decoration: const InputDecoration(
                  labelText: '时区（可选）',
                  hintText: 'Asia/Shanghai',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('containers.default_sysctls'),
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '默认 sysctls',
                  helperText: '每行一个 key=value',
                ),
              ),
              TextField(
                controller: _c('containers.dns_servers'),
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '默认 DNS',
                  helperText: '每行一个地址',
                ),
              ),
              TextField(
                controller: _c('containers.env'),
                minLines: 2,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '默认环境变量',
                  helperText: '每行一个 KEY=value',
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('默认启用 init'),
            value: _flags['containers.init'] ?? false,
            onChanged: (value) =>
                setState(() => _flags['containers.init'] = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('容器根文件系统只读'),
            value: _flags['containers.read_only'] ?? false,
            onChanged: (value) =>
                setState(() => _flags['containers.read_only'] = value),
          ),
        ]),
        _group('网络', [
          FormRow(
            children: [
              TextField(
                controller: _c('network.default_network'),
                decoration: const InputDecoration(labelText: '默认网络'),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(_select['network.network_backend']),
                initialValue: _select['network.network_backend'] ?? 'netavark',
                decoration: const InputDecoration(labelText: '网络后端'),
                items: const [
                  DropdownMenuItem(value: 'netavark', child: Text('netavark')),
                  DropdownMenuItem(value: 'cni', child: Text('cni')),
                ],
                onChanged: (value) => setState(
                  () =>
                      _select['network.network_backend'] = value ?? 'netavark',
                ),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(_select['network.firewall_driver']),
                initialValue: _select['network.firewall_driver'] ?? 'iptables',
                decoration: const InputDecoration(labelText: '防火墙驱动'),
                items: const [
                  DropdownMenuItem(value: 'iptables', child: Text('iptables')),
                  DropdownMenuItem(value: 'nftables', child: Text('nftables')),
                  DropdownMenuItem(value: 'none', child: Text('none')),
                ],
                onChanged: (value) => setState(
                  () =>
                      _select['network.firewall_driver'] = value ?? 'iptables',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('network.dns_bind_port'),
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'DNS 绑定端口'),
              ),
              DropdownButtonFormField<String>(
                key: ValueKey(_select['network.default_rootless_network_cmd']),
                initialValue:
                    _select['network.default_rootless_network_cmd'] ??
                    'slirp4netns',
                decoration: const InputDecoration(labelText: 'Rootless 网络命令'),
                items: const [
                  DropdownMenuItem(
                    value: 'slirp4netns',
                    child: Text('slirp4netns'),
                  ),
                  DropdownMenuItem(value: 'pasta', child: Text('pasta')),
                ],
                onChanged: (value) => setState(
                  () => _select['network.default_rootless_network_cmd'] =
                      value ?? 'slirp4netns',
                ),
              ),
              TextField(
                controller: _c('network.network_config_dir'),
                decoration: const InputDecoration(labelText: '网络配置目录'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _c('network.pasta_options'),
            minLines: 2,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Pasta 参数',
              helperText: '每行一个参数',
            ),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Rootless 端口转发'),
            value: _flags['network.rootless_port_forward'] ?? false,
            onChanged: (value) =>
                setState(() => _flags['network.rootless_port_forward'] = value),
          ),
        ]),
        _group('存储', [
          FormRow(
            children: [
              DropdownButtonFormField<String>(
                key: ValueKey(_select['storage.driver']),
                initialValue: _select['storage.driver'] ?? 'overlay',
                decoration: const InputDecoration(labelText: '存储驱动'),
                items: const [
                  DropdownMenuItem(value: 'overlay', child: Text('overlay')),
                  DropdownMenuItem(value: 'vfs', child: Text('vfs')),
                  DropdownMenuItem(value: 'btrfs', child: Text('btrfs')),
                  DropdownMenuItem(value: 'zfs', child: Text('zfs')),
                ],
                onChanged: (value) => setState(
                  () => _select['storage.driver'] = value ?? 'overlay',
                ),
              ),
              TextField(
                controller: _c('storage.graphroot'),
                decoration: const InputDecoration(labelText: 'Graph Root'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('storage.runroot'),
                decoration: const InputDecoration(labelText: 'Run Root'),
              ),
              TextField(
                controller: _c('storage.rootless_storage_path'),
                decoration: const InputDecoration(labelText: 'Rootless 存储路径'),
              ),
              TextField(
                controller: _c('engine.volume_path'),
                decoration: const InputDecoration(labelText: 'Volume 路径'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('storage.options.mount_program'),
                decoration: const InputDecoration(labelText: 'Mount Program'),
              ),
              TextField(
                controller: _c('storage.options.overlay.mountopt'),
                decoration: const InputDecoration(labelText: 'Mount Options'),
              ),
              TextField(
                controller: _c('storage.options.overlay.size'),
                decoration: const InputDecoration(labelText: 'Overlay 大小'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          FormRow(
            children: [
              TextField(
                controller: _c('storage.options.overlay.inodes'),
                decoration: const InputDecoration(
                  labelText: 'Overlay inode 上限',
                ),
              ),
              TextField(
                controller: _c('storage.options.overlay.mount_program'),
                decoration: const InputDecoration(
                  labelText: 'Overlay Mount Program',
                ),
              ),
            ],
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('临时存储'),
            value: _flags['storage.transient_store'] ?? false,
            onChanged: (value) =>
                setState(() => _flags['storage.transient_store'] = value),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('忽略 chown 错误'),
            subtitle: const Text('overlay.ignore_chown_errors'),
            value:
                _flags['storage.options.overlay.ignore_chown_errors'] ?? false,
            onChanged: (value) => setState(
              () =>
                  _flags['storage.options.overlay.ignore_chown_errors'] = value,
            ),
          ),
        ]),
      ],
    );
  }

  Widget _group(String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: CollapsibleSection(
        title: title,
        expanded: _open.contains(title),
        onChanged: (expanded) {
          setState(() {
            if (expanded) {
              _open.add(title);
            } else {
              _open.remove(title);
            }
          });
        },
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }
}

Map<String, String> _parseToml(String source) {
  final result = <String, String>{};
  var section = '';
  String? pendingKey;
  final pending = <String>[];
  for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (pendingKey != null) {
      pending.add(line);
      if (line.contains(']')) {
        result[pendingKey] = pending.join('\n');
        pendingKey = null;
        pending.clear();
      }
      continue;
    }
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('[[') && line.endsWith(']]')) {
      section = line;
      continue;
    }
    if (line.startsWith('[') && line.endsWith(']')) {
      section = line.substring(1, line.length - 1);
      continue;
    }
    final index = line.indexOf('=');
    if (index <= 0) continue;
    final key = line.substring(0, index).trim();
    final value = line.substring(index + 1).trim();
    final full = section.isEmpty ? key : '$section.$key';
    if (value.startsWith('[') && !value.contains(']')) {
      pendingKey = full;
      pending.add(value);
    } else {
      result[full] = value;
    }
  }
  return result;
}

List<String> _listValue(Map<String, String> map, String key, String fallback) {
  var raw = map[key] ?? fallback;
  raw = raw.trim();
  if (raw.startsWith('[')) raw = raw.substring(1);
  if (raw.endsWith(']')) raw = raw.substring(0, raw.length - 1);
  return raw
      .split(RegExp(r'[,\n]'))
      .map((value) => value.trim())
      .map(
        (value) =>
            value.length >= 2 && value.startsWith('"') && value.endsWith('"')
            ? value.substring(1, value.length - 1)
            : value,
      )
      .where((value) => value.isNotEmpty)
      .toList();
}

class _RegistryEntries {
  const _RegistryEntries({required this.insecure, required this.mirrors});

  final Set<String> insecure;
  final Set<String> mirrors;

  static _RegistryEntries merge(List<_RegistryEntries> values) {
    final result = _RegistryEntries(insecure: {}, mirrors: {});
    for (final value in values) {
      result.insecure.addAll(value.insecure);
      result.mirrors.addAll(value.mirrors);
    }
    return result;
  }
}

List<_RegistryEntries> _parseRegistryEntries(String source) {
  final insecure = <String>{};
  final mirrors = <String>{};
  String? prefix;
  var isInsecure = false;
  var inMirror = false;

  void flush() {
    if (prefix != null && isInsecure) insecure.add(prefix!);
    prefix = null;
    isInsecure = false;
    inMirror = false;
  }

  for (final raw in source.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trim();
    if (line == '[[registry]]') {
      flush();
      continue;
    }
    if (line == '[[registry.mirror]]') {
      inMirror = true;
      continue;
    }
    final index = line.indexOf('=');
    if (index <= 0) continue;
    final key = line.substring(0, index).trim();
    var value = line.substring(index + 1).trim();
    if (value.length >= 2 && value.startsWith('"') && value.endsWith('"')) {
      value = value.substring(1, value.length - 1);
    }
    if (key == 'prefix') {
      prefix = value;
    } else if (key == 'location' && inMirror && prefix != null) {
      mirrors.add('$prefix=$value');
    } else if (key == 'insecure') {
      isInsecure = value == 'true';
    }
  }
  flush();
  return [_RegistryEntries(insecure: insecure, mirrors: mirrors)];
}

String _stringValue(Map<String, String> map, String key, String fallback) {
  final raw = map[key];
  if (raw == null) return fallback;
  final trimmed = raw.trim();
  if (trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length >= 2) {
    return trimmed.substring(1, trimmed.length - 1);
  }
  return trimmed;
}

bool _boolValue(Map<String, String> map, String key, bool fallback) {
  final raw = map[key]?.trim().toLowerCase();
  if (raw == 'true') return true;
  if (raw == 'false') return false;
  return fallback;
}

List<String> _lines(String text) => text
    .split('\n')
    .map((line) => line.trim())
    .where((line) => line.isNotEmpty)
    .toList();

/// Patches `/etc/containers/storage.conf` with types that containers/storage
/// actually decodes. `ignore_chown_errors` and `inodes` are *string* values
/// (`"true"`/`"false"`, quoted sizes), while `transient_store` is a native
/// boolean. Top-level `mountopt`, `mount_program` and `volume_path` do not
/// exist in the storage table and are removed.
String patchPodmanStorageToml(
  String source, {
  required String driver,
  required String graphroot,
  required String runroot,
  required String rootlessStoragePath,
  required String mountProgram,
  required String overlayMountProgram,
  required String mountOpt,
  required String overlaySize,
  required String overlayInodes,
  required bool transientStore,
  required bool ignoreChownErrors,
}) {
  var output = source;
  output = _setToml(output, 'storage', 'driver', _quote(driver));
  output = _setToml(output, 'storage', 'graphroot', _quote(graphroot));
  output = _setToml(output, 'storage', 'runroot', _quote(runroot));
  output = _setToml(
    output,
    'storage',
    'rootless_storage_path',
    rootlessStoragePath.isEmpty ? null : _quote(rootlessStoragePath),
  );
  output = _setToml(
    output,
    'storage',
    'transient_store',
    transientStore ? 'true' : 'false',
  );
  output = _removeToml(output, 'storage', 'mount_program');
  output = _removeToml(output, 'storage', 'mountopt');
  output = _removeToml(output, 'storage', 'volume_path');
  output = _setToml(
    output,
    'storage.options',
    'mount_program',
    mountProgram.isEmpty ? null : _quote(mountProgram),
  );
  output = _setToml(
    output,
    'storage.options.overlay',
    'mount_program',
    overlayMountProgram.isEmpty ? null : _quote(overlayMountProgram),
  );
  output = _setToml(
    output,
    'storage.options.overlay',
    'mountopt',
    mountOpt.isEmpty ? null : _quote(mountOpt),
  );
  output = _setToml(
    output,
    'storage.options.overlay',
    'size',
    overlaySize.isEmpty ? null : _quote(overlaySize),
  );
  output = _setToml(
    output,
    'storage.options.overlay',
    'inodes',
    overlayInodes.isEmpty ? null : _quote(overlayInodes),
  );
  output = _setToml(
    output,
    'storage.options.overlay',
    'ignore_chown_errors',
    _quote(ignoreChownErrors ? 'true' : 'false'),
  );
  return output.trim().isEmpty ? '' : '$output\n';
}

String _quote(String value) =>
    '"${value.replaceAll('\\', '\\\\').replaceAll('"', '\\"')}"';

void _tomlString(StringBuffer out, String key, String value) {
  if (value.trim().isEmpty) return;
  out.writeln('$key = ${_quote(value.trim())}');
}

void _tomlNumber(StringBuffer out, String key, String value) {
  final number = int.tryParse(value);
  if (number == null) return;
  out.writeln('$key = $number');
}

void _tomlBool(StringBuffer out, String key, bool value) {
  out.writeln('$key = $value');
}

void _tomlList(StringBuffer out, String key, String text) {
  final values = _lines(text);
  if (values.isEmpty) return;
  out.writeln('$key = [');
  for (final value in values) {
    out.writeln('  ${_quote(value)},');
  }
  out.writeln(']');
}

String _setToml(String source, String section, String key, String? value) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final header = '[$section]';
  var headerIndex = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == header) {
      headerIndex = i;
      break;
    }
  }
  if (headerIndex < 0) {
    if (value == null || value.isEmpty) return source;
    final base = source.trim().isEmpty ? '' : '${source.trimRight()}\n\n';
    return '$base$header\n$key = $value\n';
  }
  var sectionEnd = lines.length;
  for (var i = headerIndex + 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      sectionEnd = i;
      break;
    }
  }
  var keyIndex = -1;
  for (var i = headerIndex + 1; i < sectionEnd; i++) {
    final line = lines[i].trim();
    if (line == key || line.startsWith('$key =') || line.startsWith('$key=')) {
      keyIndex = i;
      break;
    }
  }
  if (value == null || value.isEmpty) {
    if (keyIndex >= 0) lines.removeAt(keyIndex);
  } else if (keyIndex >= 0) {
    lines[keyIndex] = '$key = $value';
  } else {
    lines.insert(sectionEnd, '$key = $value');
  }
  return lines.join('\n');
}

String _removeToml(String source, String section, String key) {
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  final header = '[$section]';
  var headerIndex = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == header) {
      headerIndex = i;
      break;
    }
  }
  if (headerIndex < 0) return source;
  var sectionEnd = lines.length;
  for (var i = headerIndex + 1; i < lines.length; i++) {
    final line = lines[i].trim();
    if (line.startsWith('[') && line.endsWith(']')) {
      sectionEnd = i;
      break;
    }
  }
  final kept = <String>[];
  for (var i = 0; i < lines.length; i++) {
    if (i > headerIndex && i < sectionEnd) {
      final line = lines[i].trim();
      if (line.startsWith('$key =') || line.startsWith('$key=')) continue;
    }
    kept.add(lines[i]);
  }
  return kept.join('\n');
}
