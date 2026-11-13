import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/ai_config.dart';
import '../../core/build_info.dart';
import '../../core/enrollment.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../ai/ai_tools.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  String? _health;
  String? _serverVersion;
  bool _checking = false;
  Map<String, dynamic>? _update;
  bool _updateBusy = false;

  final _aiTools = buildAiTools();
  final _sensitivePathController = TextEditingController();
  AiConfig? _aiConfig;
  Set<String> _enabledTools = {};
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
      setState(() => _update = json as Map<String, dynamic>?);
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
    setState(() => _updateBusy = true);
    try {
      final result = await _api.postJson(
        '/api/v1/update/apply',
        null,
        timeout: const Duration(minutes: 5),
      );
      final message = result is Map
          ? result['message'] as String? ?? '更新完成'
          : '更新完成';
      _toast(message);
    } catch (error) {
      _toast('更新失败：${describeError(error)}');
    } finally {
      if (mounted) setState(() => _updateBusy = false);
    }
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
    return Column(
      children: [
        const PageHeader(title: '设置', subtitle: '连接、凭据与客户端信息'),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 720,
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
                        _row('创建时间', enrollment.createdAt),
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
                              icon: const Icon(Icons.network_check, size: 16),
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
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: 720,
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
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _row(
                                '安装方式',
                                installMode == 'binary' ? '发布二进制' : '源码构建',
                              ),
                              _row(
                                '更新通道',
                                (_update?['channel'] as String?) ?? '-',
                              ),
                              _row(
                                '当前版本',
                                (_update?['current_version'] as String?) ?? '-',
                              ),
                              _row(
                                '最新版本',
                                latestVersion.isEmpty ? '未检查' : latestVersion,
                              ),
                              _row(
                                '上次检查',
                                checkedAt > 0
                                    ? DateTime.fromMillisecondsSinceEpoch(
                                        checkedAt * 1000,
                                      ).toLocal().toString()
                                    : '从未',
                              ),
                              if (updatable)
                                _row('每日检查', scheduled ? '已启用（04:17）' : '未启用'),
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
                                      icon: const Icon(Icons.refresh, size: 16),
                                      label: const Text('检查更新'),
                                    ),
                                    FilledButton.icon(
                                      onPressed: _updateBusy || !updateAvailable
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
                const SizedBox(height: 14),
                SizedBox(
                  width: 720,
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
                const SizedBox(height: 14),
                SizedBox(
                  width: 720,
                  child: PanelCard(
                    title: 'AI 工具权限',
                    trailing: _aiLoading
                        ? null
                        : StatusPill(
                            text: '${_enabledTools.length}/${_aiTools.length}',
                            good: _enabledTools.isNotEmpty,
                          ),
                    child: _aiLoading
                        ? const LoadingView()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                      (tool) => tool.name == 'add_cron_job',
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
                const SizedBox(height: 14),
                SizedBox(
                  width: 720,
                  child: PanelCard(
                    title: 'AI 敏感文件路径',
                    child: _aiLoading
                        ? const LoadingView()
                        : Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
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
                                          () => _sensitivePaths.remove(path),
                                        ),
                                        deleteIcon: const Icon(
                                          Icons.close,
                                          size: 14,
                                        ),
                                      ),
                                  ],
                                ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _sensitivePathController,
                                      decoration: const InputDecoration(
                                        labelText: '添加敏感路径',
                                        hintText: '/etc/shadow 或 /root/.ssh',
                                      ),
                                      onSubmitted: (_) => _addSensitivePath(),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  OutlinedButton.icon(
                                    onPressed: _addSensitivePath,
                                    icon: const Icon(Icons.add, size: 16),
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
                const SizedBox(height: 14),
                SizedBox(
                  width: 720,
                  child: PanelCard(
                    title: '关于',
                    child: Column(
                      children: [
                        _row('产品', 'Hampanel $fullClientVersion'),
                        _row('产品标识', productId),
                        _row('官网', officialSite),
                        _row('协议', 'GPL-3.0-or-later'),
                        _row('传输', 'HTTP/1.1 + WebSocket over mutual TLS'),
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
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _toolGroup(String title, List<AiTool> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text(
            title,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: hampanelMuted,
            ),
          ),
        ),
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
              style: monospace.copyWith(
                fontSize: 11.5,
                color: hampanelInkSoft,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
