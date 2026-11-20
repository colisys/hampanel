import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/ai_config.dart';
import '../../core/build_info.dart';
import '../../core/client_settings.dart';
import 'client_update_panel.dart';
import '../../core/format.dart';
import '../../core/enrollment.dart';
import '../../core/platform_support.dart';
import '../../core/session.dart';
import '../../ui/collapsible.dart';
import '../../ui/layout.dart';
import '../../ui/remote_picker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../ai/ai_tools.dart';
import 'host_settings_section.dart';
import 'notification_settings.dart';

enum _SettingsTab { general, ai, host, notifications, about }

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  _SettingsTab _tab = _SettingsTab.general;
  String? _health;
  String? _serverVersion;
  bool _checking = false;
  Map<String, dynamic>? _update;
  bool _updateBusy = false;
  final _daemonMirror = TextEditingController();
  String? _daemonChannel;
  bool _daemonSaving = false;

  final _aiTools = buildAiTools();
  final _sensitivePathController = TextEditingController();
  AiConfig? _aiConfig;
  Set<String> _enabledTools = {};
  static const _aiToolGroupTitles = [
    '只读工具',
    '修改类工具（需审批）',
    '高风险工具（默认关闭）',
  ];
  final Set<String> _expandedToolGroups = {'只读工具'};
  List<String> _sensitivePaths = [];
  bool _aiLoading = true;
  bool _aiSaving = false;

  @override
  void initState() {
    super.initState();
    _check();
    _loadUpdate();
    _loadAiSettings();
  }

  @override
  void dispose() {
    _sensitivePathController.dispose();
    _daemonMirror.dispose();
    super.dispose();
  }

  Future<void> _loadAiSettings() async {
    final config = await AiConfig.load() ?? AiConfig.defaults();
    AiToolPreferences.apply(config, _aiTools);
    if (!mounted) return;
    setState(() {
      _aiConfig = config;
      _enabledTools = {...AiToolPreferences.enabled.value};
      _sensitivePaths = List<String>.from(
        AiToolPreferences.sensitivePaths.value,
      );
      _aiLoading = false;
    });
  }

  Future<void> _saveAiSettings() async {
    setState(() => _aiSaving = true);
    try {
      final config = _aiConfig ?? AiConfig.defaults();
      config.enabledTools = _enabledTools.toList()..sort();
      config.sensitivePaths = List<String>.from(_sensitivePaths);
      await config.save();
      AiToolPreferences.apply(config, _aiTools);
      if (!mounted) return;
      setState(() => _aiConfig = config);
      _toast('AI 工具权限已保存');
    } catch (error) {
      _toast('保存失败：$error');
    } finally {
      if (mounted) setState(() => _aiSaving = false);
    }
  }

  void _resetAiDefaults() {
    setState(() {
      _enabledTools = AiToolPreferences.defaultsFor(_aiTools);
      _sensitivePaths = AiToolPreferences.defaultsForSensitivePaths;
    });
    _toast('已恢复默认，点击保存生效');
  }

  void _addSensitivePath() {
    var path = _sensitivePathController.text.trim();
    while (path.length > 1 && (path.endsWith('/') || path.endsWith('\\'))) {
      path = path.substring(0, path.length - 1);
    }
    if (path.isEmpty) return;
    final isAbsolute =
        path.startsWith('/') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
    if (!isAbsolute || path.contains('\n') || path.length > 1024) {
      _toast('请输入绝对路径（Linux 以 / 开头，Windows 如 C:\\path）');
      return;
    }
    if (_sensitivePaths.contains(path)) {
      _toast('路径已存在');
      return;
    }
    setState(() => _sensitivePaths.add(path));
    _sensitivePathController.clear();
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  ApiClient get _api => PanelScope.of(context).api;

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _health = null;
    });
    try {
      final json = await _api.getJson('/api/v1/health');
      final map = json as Map<String, dynamic>? ?? const {};
      setState(() {
        _serverVersion = map['version'] as String? ?? '?';
        _health = '连接正常 · 服务端 ${_serverVersion!}';
      });
    } catch (error) {
      setState(() => _health = describeError(error));
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _loadUpdate() async {
    try {
      final json = await _api.getJson('/api/v1/update');
      if (!mounted) return;
      final map = json as Map<String, dynamic>?;
      setState(() {
        _update = map;
        _daemonChannel = (map?['channel'] as String?) ?? 'stable';
        _daemonMirror.text = (map?['github_mirror'] as String?) ?? '';
      });
    } catch (_) {
      // update status is optional
    }
  }

  Future<void> _checkUpdate() async {
    setState(() => _updateBusy = true);
    try {
      await _api.postJson('/api/v1/update/check', null);
      await _loadUpdate();
      _toast('更新检查完成');
    } catch (error) {
      _toast('检查失败：${describeError(error)}');
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<void> _applyUpdate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('立即更新'),
        content: const Text('将下载最新版本、替换 hampaneld 并重启服务，期间面板会短暂断开。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('更新'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    if (!mounted) return;
    setState(() => _updateBusy = true);
    var before = _serverVersion;
    if (before == null || before == '?') {
      try {
        final health = await _api.getJson(
          '/api/v1/health',
          timeout: const Duration(seconds: 5),
        );
        before = (health as Map<String, dynamic>?)?['version'] as String?;
        if (mounted && before != null) {
          setState(() => _serverVersion = before);
        }
      } catch (_) {}
    }
    if (!mounted) return;
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit('update.apply', title: '应用客户端更新');
      if (!mounted) return;
      _toast('已提交任务：${task.title}');
      // The daemon schedules its own restart once the binary is replaced, so
      // wait for the version to change rather than for the stream to finish.
      await _waitForRestart(before);
      if (!mounted) return;
      await _loadUpdate();
    } catch (error) {
      final restarted = await _waitForRestart(before);
      if (restarted) {
        _toast('更新已应用，服务已重启');
        await _loadUpdate();
      } else {
        _toast('更新失败：${describeError(error)}');
      }
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<bool> _waitForRestart(String? before) async {
    if (before == null || before == '?' || before.isEmpty) return false;
    for (var attempt = 0; attempt < 20; attempt++) {
      await Future<void>.delayed(const Duration(seconds: 2));
      if (!mounted) return false;
      try {
        final json = await _api.getJson(
          '/api/v1/health',
          timeout: const Duration(seconds: 3),
        );
        final current = (json as Map<String, dynamic>?)?['version'] as String?;
        if (current != null && current != before) {
          if (mounted) {
            setState(() {
              _serverVersion = current;
              _health = '连接正常 · 服务端 $current';
            });
          }
          return true;
        }
      } catch (_) {
        // Expected while the service is between stop and start.
      }
    }
    return false;
  }

  Future<void> _toggleUpdateSchedule() async {
    final scheduled = _update?['scheduled'] == true;
    setState(() => _updateBusy = true);
    try {
      if (scheduled) {
        await _api.deleteJson('/api/v1/update/schedule');
        _toast('已关闭每日更新检查');
      } else {
        await _api.postJson('/api/v1/update/schedule', null);
        _toast('已启用每日更新检查');
      }
      await _loadUpdate();
    } catch (error) {
      _toast('操作失败：${describeError(error)}');
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
  }

  Future<void> _saveDaemonUpdateConfig() async {
    setState(() => _daemonSaving = true);
    try {
      await _api.putJson('/api/v1/update/config', {
        'channel': _daemonChannel ?? 'stable',
        'github_mirror': _daemonMirror.text.trim(),
      });
      await _loadUpdate();
      _toast('受控端更新配置已保存');
    } catch (error) {
      _toast('保存失败：${describeError(error)}');
    } finally {
      if (mounted) setState(() => _daemonSaving = false);
    }
  }

  Future<void> _copyEnrollment() async {
    final enrollment = PanelScope.of(context).enrollment;
    await Clipboard.setData(
      ClipboardData(
        text: const JsonEncoder.withIndent('  ').convert(enrollment.toJson()),
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('注册凭据已复制到剪贴板')));
  }

  Future<void> _openConfigDirectory() async {
    final directory = Enrollment.configDirectory();
    await directory.create(recursive: true);
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [directory.path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [directory.path]);
      } else {
        await Process.run('xdg-open', [directory.path]);
      }
    } catch (_) {
      // ignore file manager launch failures
    }
  }

  @override
  Widget build(BuildContext context) {
    final enrollment = PanelScope.of(context).enrollment;
    final updatable = _update?['updatable'] == true;
    final updateAvailable = _update?['update_available'] == true;
    final scheduled = _update?['scheduled'] == true;
    final installMode = _update?['install_mode'] as String? ?? 'source';
    final latestVersion = (_update?['latest_version'] as String?) ?? '';
    final updateError = (_update?['error_message'] as String?) ?? '';
    final checkedAt = (_update?['checked_at'] as num?)?.toInt() ?? 0;
    final compact = MediaQuery.sizeOf(context).width < 720;
    return Column(
      children: [
        PageHeader(
          title: '设置',
          actions: [PageRefreshButton(onPressed: _refreshAll)],
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (!compact) ...[
                SubNav(
                  items: const ['常规', 'AI', '主机', '通知', '关于'],
                  index: _tab.index,
                  onChanged: (index) =>
                      setState(() => _tab = _SettingsTab.values[index]),
                ),
                const VerticalDivider(width: 1),
              ],
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.fromLTRB(
                    compact ? 12 : 24,
                    4,
                    compact ? 12 : 24,
                    24,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 14,
                    children: [
                      if (_tab == _SettingsTab.general)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: '连接',
                            trailing: StatusPill(
                              text: _checking
                                  ? '检测中'
                                  : (_health == null ? '未检测' : '已检测'),
                              good: _health?.startsWith('连接正常') ?? false,
                            ),
                            child: Column(
                              children: [
                                _row('Endpoint', enrollment.endpoint),
                                _row(
                                  '入口前缀',
                                  enrollment.entryPrefix.isEmpty
                                      ? '未启用'
                                      : enrollment.entryPrefix,
                                ),
                                _row('客户端 CN', enrollment.clientCn),
                                _row('服务端版本', _serverVersion ?? '检测中'),
                                _row(
                                  '创建时间',
                                  formatTimestamp(enrollment.createdAt),
                                ),
                                _row('配置目录', Enrollment.configDirectory().path),
                                if (_health != null) ...[
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      _health!,
                                      style: TextStyle(
                                        fontSize: 11.5,
                                        color: hampanelMuted,
                                      ),
                                    ),
                                  ),
                                ],
                                const SizedBox(height: 12),
                                Row(
                                  children: [
                                    FilledButton.icon(
                                      onPressed: _checking ? null : _check,
                                      icon: const Icon(
                                        Icons.network_check,
                                        size: 16,
                                      ),
                                      label: const Text('测试连接'),
                                    ),
                                    const SizedBox(width: 10),
                                    OutlinedButton.icon(
                                      onPressed: _copyEnrollment,
                                      icon: const Icon(
                                        Icons.copy_all_outlined,
                                        size: 16,
                                      ),
                                      label: const Text('复制注册凭据'),
                                    ),
                                    if (PlatformSupport
                                        .openConfigDirectory) ...[
                                      const SizedBox(width: 10),
                                      OutlinedButton.icon(
                                        onPressed: _openConfigDirectory,
                                        icon: const Icon(
                                          Icons.folder_open_outlined,
                                          size: 16,
                                        ),
                                        label: const Text('打开配置目录'),
                                      ),
                                    ],
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_tab == _SettingsTab.general)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: '更新',
                            trailing: _update == null
                                ? null
                                : StatusPill(
                                    text: updatable
                                        ? (updateAvailable ? '可更新' : '已是最新')
                                        : '源码安装',
                                    good: !updateAvailable,
                                  ),
                            child: _update == null
                                ? const LoadingView()
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      _row(
                                        '安装方式',
                                        installMode == 'binary'
                                            ? '发布二进制'
                                            : '源码构建',
                                      ),
                                      _updateRow(
                                        channel:
                                            DropdownButtonFormField<String>(
                                              initialValue:
                                                  _daemonChannel ?? 'stable',
                                              decoration: const InputDecoration(
                                                labelText: '更新通道',
                                              ),
                                              items: const [
                                                DropdownMenuItem(
                                                  value: 'stable',
                                                  child: Text('stable'),
                                                ),
                                                DropdownMenuItem(
                                                  value: 'nightly',
                                                  child: Text('nightly'),
                                                ),
                                              ],
                                              onChanged: updatable
                                                  ? (value) => setState(
                                                      () => _daemonChannel =
                                                          value,
                                                    )
                                                  : null,
                                            ),
                                        mirror: TextField(
                                          controller: _daemonMirror,
                                          enabled: updatable,
                                          decoration: const InputDecoration(
                                            labelText: 'GitHub 镜像（可选）',
                                            hintText: 'https://ghproxy.example',
                                          ),
                                        ),
                                        save: OutlinedButton(
                                          onPressed: updatable && !_daemonSaving
                                              ? _saveDaemonUpdateConfig
                                              : null,
                                          child: Text(
                                            _daemonSaving ? '保存中…' : '保存',
                                          ),
                                        ),
                                      ),
                                      Text(
                                        '镜像用于受控端更新下载；留空表示直连 GitHub。',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: hampanelMuted,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      _row(
                                        '当前版本',
                                        (_update?['current_version']
                                                as String?) ??
                                            '-',
                                      ),
                                      _row(
                                        '最新版本',
                                        latestVersion.isEmpty
                                            ? '未检查'
                                            : latestVersion,
                                      ),
                                      _row(
                                        '上次检查',
                                        checkedAt > 0
                                            ? formatTimestamp(checkedAt)
                                            : '从未',
                                      ),
                                      if (updatable)
                                        _row(
                                          '每日检查',
                                          scheduled ? '已启用（04:17）' : '未启用',
                                        ),
                                      if (updateError.isNotEmpty) ...[
                                        const SizedBox(height: 6),
                                        Text(
                                          updateError,
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: hampanelDanger,
                                          ),
                                        ),
                                      ],
                                      const SizedBox(height: 8),
                                      Text(
                                        updatable
                                            ? '发布二进制安装会通过 GitHub Release 检查新版本；更新会替换二进制并重启服务。'
                                            : '源码安装不启用自动更新检查。需要更新时请用同一方式重新构建部署。',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: hampanelMuted,
                                          height: 1.5,
                                        ),
                                      ),
                                      if (updatable) ...[
                                        const SizedBox(height: 12),
                                        Wrap(
                                          spacing: 10,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton.icon(
                                              onPressed: _updateBusy
                                                  ? null
                                                  : _checkUpdate,
                                              icon: const Icon(
                                                Icons.refresh,
                                                size: 16,
                                              ),
                                              label: const Text('检查更新'),
                                            ),
                                            FilledButton.icon(
                                              onPressed:
                                                  _updateBusy ||
                                                      !updateAvailable
                                                  ? null
                                                  : _applyUpdate,
                                              icon: const Icon(
                                                Icons.system_update_alt,
                                                size: 16,
                                              ),
                                              label: const Text('立即更新'),
                                            ),
                                            OutlinedButton.icon(
                                              onPressed: _updateBusy
                                                  ? null
                                                  : _toggleUpdateSchedule,
                                              icon: const Icon(
                                                Icons.schedule,
                                                size: 16,
                                              ),
                                              label: Text(
                                                scheduled ? '关闭每日检查' : '启用每日检查',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ],
                                  ),
                          ),
                        ),
                      if (_tab == _SettingsTab.general)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: '证书指纹',
                            child: Column(
                              children: [
                                _row('CA SHA-256', enrollment.caSha256),
                                _row('服务端 SHA-256', enrollment.serverSha256),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '客户端只信任该 CA，并强制要求服务端提供匹配证书；没有有效客户端证书的连接会在 TLS 层被拒绝。',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hampanelMuted,
                                      height: 1.5,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_tab == _SettingsTab.general)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: '客户端',
                            child: Wrap(
                              spacing: 12,
                              runSpacing: 8,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                SizedBox(
                                  width: 190,
                                  child: DropdownButtonFormField<int>(
                                    initialValue: ClientSettings
                                        .instance
                                        .overviewRefreshSeconds,
                                    decoration: const InputDecoration(
                                      labelText: '概览刷新间隔',
                                    ),
                                    items: [
                                      for (final seconds
                                          in ClientSettings.refreshChoices)
                                        DropdownMenuItem(
                                          value: seconds,
                                          child: Text('$seconds 秒'),
                                        ),
                                    ],
                                    onChanged: _setRefreshSeconds,
                                  ),
                                ),
                                Text(
                                  '影响概览指标采样频率。',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: hampanelMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (_tab == _SettingsTab.general)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: const PanelCard(
                            title: '管理端更新',
                            child: ClientUpdatePanel(),
                          ),
                        ),
                      if (_tab == _SettingsTab.ai)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: 'AI 工具权限',
                            trailing: _aiLoading
                                ? null
                                : StatusPill(
                                    text:
                                        '${_enabledTools.length}/${_aiTools.length}',
                                    good: _enabledTools.isNotEmpty,
                                  ),
                            child: _aiLoading
                                ? const LoadingView()
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        '勾选允许 AI 助手调用的工具。修改类工具每次执行仍需人工批准；'
                                        '计划任务工具默认关闭，勾选后创建任务也同样需要批准。',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: hampanelMuted,
                                          height: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          TextButton(
                                            onPressed: () => setState(
                                              () => _expandedToolGroups.addAll(
                                                _aiToolGroupTitles,
                                              ),
                                            ),
                                            child: const Text('展开全部'),
                                          ),
                                          TextButton(
                                            onPressed: () => setState(
                                              () => _expandedToolGroups.clear(),
                                            ),
                                            child: const Text('收起全部'),
                                          ),
                                        ],
                                      ),
                                      _toolGroup(
                                        '只读工具',
                                        _aiTools
                                            .where(
                                              (tool) =>
                                                  !tool.mutating &&
                                                  tool.name != 'add_cron_job',
                                            )
                                            .toList(),
                                      ),
                                      _toolGroup(
                                        '修改类工具（需审批）',
                                        _aiTools
                                            .where(
                                              (tool) =>
                                                  tool.mutating &&
                                                  tool.name != 'add_cron_job',
                                            )
                                            .toList(),
                                      ),
                                      _toolGroup(
                                        '高风险工具（默认关闭）',
                                        _aiTools
                                            .where(
                                              (tool) =>
                                                  tool.name == 'add_cron_job',
                                            )
                                            .toList(),
                                      ),
                                      const SizedBox(height: 6),
                                      Row(
                                        children: [
                                          FilledButton.icon(
                                            onPressed: _aiSaving
                                                ? null
                                                : _saveAiSettings,
                                            icon: const Icon(
                                              Icons.save_outlined,
                                              size: 16,
                                            ),
                                            label: Text(
                                              _aiSaving ? '保存中…' : '保存 AI 权限',
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          OutlinedButton(
                                            onPressed: _resetAiDefaults,
                                            child: const Text('恢复默认'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      if (_tab == _SettingsTab.ai)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: 'AI 敏感文件路径',
                            child: _aiLoading
                                ? const LoadingView()
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'AI 读取这些路径或其子路径时必须人工批准；其他文件读取自动执行。'
                                        '修改类操作始终需要批准。',
                                        style: TextStyle(
                                          fontSize: 11.5,
                                          color: hampanelMuted,
                                          height: 1.5,
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      if (_sensitivePaths.isEmpty)
                                        Text(
                                          '未配置敏感路径',
                                          style: TextStyle(
                                            fontSize: 11.5,
                                            color: hampanelMuted,
                                          ),
                                        )
                                      else
                                        Wrap(
                                          spacing: 6,
                                          runSpacing: 6,
                                          children: [
                                            for (final path in _sensitivePaths)
                                              InputChip(
                                                label: Text(
                                                  path,
                                                  style: monospace.copyWith(
                                                    fontSize: 11,
                                                  ),
                                                ),
                                                onDeleted: () => setState(
                                                  () => _sensitivePaths.remove(
                                                    path,
                                                  ),
                                                ),
                                                deleteIcon: const Icon(
                                                  Icons.close,
                                                  size: 14,
                                                ),
                                              ),
                                          ],
                                        ),
                                      const SizedBox(height: 10),
                                      FieldWithActions(
                                        field: RemotePathField(
                                          api: _api,
                                          controller: _sensitivePathController,
                                          label: '添加敏感路径',
                                          hintText:
                                              '/etc/shadow 或 /root/.ssh',
                                          allowFiles: true,
                                          onPicked: (_) => _addSensitivePath(),
                                        ),
                                        actions: [
                                          OutlinedButton.icon(
                                            onPressed: _addSensitivePath,
                                            icon: const Icon(
                                              Icons.add,
                                              size: 16,
                                            ),
                                            label: const Text('添加'),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 10),
                                      Row(
                                        children: [
                                          FilledButton.icon(
                                            onPressed: _aiSaving
                                                ? null
                                                : _saveAiSettings,
                                            icon: const Icon(
                                              Icons.save_outlined,
                                              size: 16,
                                            ),
                                            label: const Text('保存路径配置'),
                                          ),
                                          const SizedBox(width: 10),
                                          OutlinedButton(
                                            onPressed: _resetAiDefaults,
                                            child: const Text('恢复默认'),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      if (_tab == _SettingsTab.host)
                        const HostSettingsSection(),
                      if (_tab == _SettingsTab.notifications)
                        NotificationSettings(key: ObjectKey(_api), api: _api),
                      if (_tab == _SettingsTab.about)
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 720),
                          child: PanelCard(
                            title: '关于',
                            child: Column(
                              children: [
                                _row('产品', 'Hampanel $fullClientVersion'),
                                _row('产品标识', productId),
                                _row('官网', officialSite),
                                _row('协议', 'GPL-3.0-or-later'),
                                _row(
                                  '传输',
                                  'HTTP/1.1 + WebSocket over mutual TLS',
                                ),
                                const SizedBox(height: 6),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: Text(
                                    '本项目为独立 CleanRoom 实现，未复制任何参考面板的代码或算法。',
                                    style: TextStyle(
                                      fontSize: 11,
                                      color: hampanelMuted,
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: OutlinedButton.icon(
                                    onPressed: () => showLicensePage(
                                      context: context,
                                      applicationName: 'Hampanel',
                                      applicationVersion: fullClientVersion,
                                      applicationLegalese: 'GPL-3.0-or-later',
                                    ),
                                    icon: const Icon(
                                      Icons.gavel_outlined,
                                      size: 16,
                                    ),
                                    label: const Text('开源许可'),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (compact)
          Container(
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: hampanelBorder)),
            ),
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 6),
            child: SafeArea(
              top: false,
              child: SubNavBar(
                items: const ['常规', 'AI', '主机', '通知', '关于'],
                index: _tab.index,
                onChanged: (index) =>
                    setState(() => _tab = _SettingsTab.values[index]),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _refreshAll() async {
    await Future.wait([
      _check(),
      _loadUpdate(),
      _loadAiSettings(),
    ]);
  }

  Future<void> _setRefreshSeconds(int? value) async {
    if (value == null) return;
    ClientSettings.instance.overviewRefreshSeconds = value;
    await ClientSettings.instance.save();
    if (mounted) setState(() {});
  }

  Widget _toolGroup(String title, List<AiTool> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    return CollapsibleSection(
      title: title,
      subtitle:
          '${tools.where((tool) => _enabledTools.contains(tool.name)).length}/${tools.length}',
      expanded: _expandedToolGroups.contains(title),
      onChanged: (expanded) {
        setState(() {
          if (expanded) {
            _expandedToolGroups.add(title);
          } else {
            _expandedToolGroups.remove(title);
          }
        });
      },
      padding: const EdgeInsets.only(top: 4, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final tool in tools)
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _enabledTools.contains(tool.name),
              onChanged: (value) {
                setState(() {
                  if (value == true) {
                    _enabledTools.add(tool.name);
                  } else {
                    _enabledTools.remove(tool.name);
                  }
                });
              },
              title: Text(
                tool.name,
                style: TextStyle(
                  fontSize: 12.5,
                  color: tool.name == 'add_cron_job' ? hampanelDanger : null,
                ),
              ),
              subtitle: Text(
                tool.description,
                style: TextStyle(fontSize: 11, color: hampanelMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _updateRow({
    required Widget channel,
    required Widget mirror,
    required Widget save,
  }) {
    final compact = MediaQuery.sizeOf(context).width < 620;
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          channel,
          const SizedBox(height: 10),
          mirror,
          const SizedBox(height: 10),
          Align(alignment: Alignment.centerRight, child: save),
        ],
      );
    }
    return Row(
      children: [
        SizedBox(width: 190, child: channel),
        const SizedBox(width: 12),
        Expanded(child: mirror),
        const SizedBox(width: 8),
        save,
      ],
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace.copyWith(fontSize: 11.5, color: hampanelInkSoft),
            ),
          ),
        ],
      ),
    );
  }
}
