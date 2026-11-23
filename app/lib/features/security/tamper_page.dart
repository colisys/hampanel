import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/remote_picker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class _RegularFiles extends HostDirectorySource {
  _RegularFiles(super.api, this.title);

  final _regular = <String>{};

  @override
  final String title;

  @override
  Future<List<RemotePickerEntry>> list(
    String path, {
    bool includeFiles = false,
  }) async {
    final entries = await super.list(path, includeFiles: true);
    _regular.addAll(
      entries
          .where((e) => !e.isDirectory && e.subtitle.startsWith('-'))
          .map((e) => e.path),
    );
    return entries;
  }

  @override
  bool selectable(String path) => _regular.contains(path);
}

class TamperPage extends StatefulWidget {
  const TamperPage({super.key});

  @override
  State<TamperPage> createState() => _TamperPageState();
}

class _TamperPageState extends State<TamperPage> {
  bool _changingRule = false;
  bool _observing = false;
  String? _observation;
  Map<String, dynamic>? _status;
  Map<String, dynamic>? _lsm;
  String? _lsmError;
  bool _lsmLoading = true;
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
    // The legacy chattr/sampler response must not depend on the LSM helper.
    final lsmLoad = _changingRule ? Future<void>.value() : _loadLsm();
    try {
      final status = await _api.getJson('/api/v1/security/tamper');
      if (!mounted) return;
      setState(() {
        _status = status as Map<String, dynamic>? ?? const {};
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
    await lsmLoad;
  }

  Future<void> _loadLsm() async {
    setState(() {
      _lsmLoading = true;
      _lsmError = null;
    });
    try {
      final snapshot = await _api.getJson('/api/v1/security/tamper/lsm');
      if (!mounted) return;
      setState(() => _lsm = snapshot as Map<String, dynamic>);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _lsm = null;
        _lsmError = describeError(error);
      });
    } finally {
      if (mounted) setState(() => _lsmLoading = false);
    }
  }

  Future<void> _observe() async {
    if (_observing) return;
    setState(() {
      _observing = true;
      _observation = null;
    });
    try {
      final path = await showRemotePicker(
        context,
        source: _RegularFiles(_api, '选择要观察的普通文件'),
        allowFiles: true,
        confirmLabel: '观察普通文件',
      );
      if (path == null || !mounted) return;
      final result = await _api.postJson('/api/v1/security/tamper/detect', {
        'path': path,
      }, timeout: const Duration(seconds: 25));
      if (!mounted) return;
      final count = result is Map ? result['write_attempts'] : null;
      if (count is! int ||
          count < 0 ||
          result['mode'] != 'ebpf_detect' ||
          result['blocking'] != false) {
        throw const FormatException('未收到完整的监测结果');
      }
      setState(() => _observation = '$path：本次观察到 $count 次 vfs_write 调用。');
    } catch (error) {
      if (mounted) setState(() => _observation = describeError(error));
    } finally {
      if (mounted) setState(() => _observing = false);
    }
  }

  Future<void> _changeRule({String? removePath}) async {
    if (_changingRule) return;
    setState(() => _changingRule = true);
    const endpoint = '/api/v1/security/tamper/lsm';
    try {
      if (removePath != null) {
        final ok = await confirmDialog(
          context,
          title: '移除 eBPF 规则?',
          message: '移除 $removePath 的持续防护规则，不改变 chattr 属性。',
          confirmLabel: '移除',
          danger: true,
        );
        if (ok && mounted) {
          await _applyLsm('$endpoint/remove', removePath, '已移除 LSM 规则');
        }
      } else {
        final path = await showRemotePicker(
          context,
          source: _RegularFiles(_api, '选择要持续防护的普通文件'),
          allowFiles: true,
          confirmLabel: '添加 eBPF 规则',
        );
        if (path != null && mounted) {
          await _applyLsm(endpoint, path, '已添加 LSM 规则');
        }
      }
    } finally {
      if (mounted) setState(() => _changingRule = false);
    }
  }

  Future<void> _applyLsm(String endpoint, String path, String message) async {
    try {
      final snapshot = await _api.postJson(endpoint, {'path': path});
      if (!mounted) return;
      setState(() {
        _lsm = snapshot as Map<String, dynamic>;
        _lsmError = null;
      });
      _toast(message);
    } catch (error) {
      _toast(describeError(error));
      if (mounted) await _loadLsm();
    }
  }

  Future<void> _add() async {
    final picked = await showRemotePicker(
      context,
      source: HostDirectorySource(_api),
      allowFiles: true,
      confirmLabel: '保护该路径',
    );
    if (picked == null || !mounted) return;
    await _apply('/api/v1/security/tamper', picked, '已保护 $picked');
  }

  Future<void> _remove(String path) async {
    final ok = await confirmDialog(
      context,
      title: '解除保护?',
      message: '会清除 $path 的不可变属性，之后可以再次修改。',
      confirmLabel: '解除',
      danger: true,
    );
    if (!ok) return;
    await _apply('/api/v1/security/tamper/remove', path, '已解除 $path');
  }

  Future<void> _apply(String endpoint, String path, String message) async {
    try {
      final json = await _api.postJson(endpoint, {'path': path});
      final map = json as Map<String, dynamic>? ?? const {};
      if (map['ok'] != true) {
        _toast((map['output'] as String? ?? '操作失败').trim());
        return;
      }
      if (!mounted) return;
      _toast(message);
      await _load();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    showAppSnackBar(context, SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    final entries = ((status?['entries'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final ready = status?['tooling'] == true;
    final detection = status?['ebpf_detection'] == true;
    final lsm = _lsm;
    final rules = (lsm?['entries'] as List? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final capacity = lsm?['capacity'] as int? ?? 64;
    return Scaffold(
      appBar: AppBar(
        title: const Text('文件防篡改'),
        actions: [
          PageRefreshButton(
            onPressed: _changingRule ? null : _load,
            refreshing: _loading || _lsmLoading,
          ),
          const SizedBox(width: 8),
        ],
      ),
      bottomNavigationBar: ActionDock(
        actions: [
          ActionDockItem(
            icon: Icons.add_moderator_outlined,
            label: 'chattr 保护路径',
            onPressed: ready && !_loading && _error == null ? _add : null,
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? Padding(
              padding: pageContentPadding(context),
              child: ErrorBanner(message: _error!, onRetry: _load),
            )
          : ListView(
              padding: pageContentPadding(context),
              children: [
                PanelCard(
                  title: '不可变保护（阻止修改）',
                  trailing: StatusPill(text: ready ? '可用' : '不可用', good: ready),
                  child: Text(
                    ready
                        ? '使用 chattr 设置不可变属性；是否生效取决于权限和文件系统。'
                        : '缺少 chattr/lsattr，无法进行不可变保护。',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.6,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: 'eBPF 写入监测（不阻止修改）',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '对选定的普通文件观察约 5 秒，仅统计 vfs_write 调用，不代表写入成功，也不涵盖所有修改。不会持续监控或加入保护列表。',
                      ),
                      if (!detection)
                        Text('监测不可用：${status?['ebpf_reason'] ?? '未检测到支持'}'),
                      TextButton(
                        onPressed: detection && !_observing ? _observe : null,
                        child: Text(_observing ? '观察中…' : '选择文件并观察'),
                      ),
                      if (_observation != null) Text(_observation!),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: 'eBPF LSM 持续防护',
                  trailing: StatusPill(
                    text: _lsmError != null
                        ? '不可用'
                        : _lsmLoading
                        ? '加载中'
                        : lsm?['degraded'] == true
                        ? '部分失效'
                        : '已连接',
                    good:
                        _lsmError == null &&
                        !_lsmLoading &&
                        lsm?['degraded'] != true,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        '仅限 ext 文件系统上的普通文件（包含硬链接）；最多 64 个 inode。阻止写打开、写入、截断、重命名、删除及新建共享可写映射；已有可写 mmap 不在防护范围内。重启后由 daemon 启动时按文件身份恢复。',
                      ),
                      if (_lsmError != null) Text('LSM 状态不可用：$_lsmError'),
                      if (!_lsmLoading && _lsmError == null && rules.isEmpty)
                        const Text('尚未配置 LSM 规则。'),
                      for (final rule in rules)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text('${rule['path']}', style: monospace),
                          subtitle: Text(
                            [
                              rule['identity_matches'] == true
                                  ? '路径身份匹配'
                                  : '路径身份不匹配',
                              rule['inode_guarded'] == true
                                  ? 'inode 已防护'
                                  : 'inode 未防护',
                            ].join(' · '),
                          ),
                          trailing: IconButton(
                            tooltip: '移除 eBPF 规则',
                            icon: const Icon(Icons.delete_outline),
                            onPressed: _changingRule || _lsmLoading
                                ? null
                                : () => _changeRule(
                                    removePath: rule['path'] as String,
                                  ),
                          ),
                        ),
                      TextButton(
                        onPressed:
                            lsm != null &&
                                !_lsmLoading &&
                                !_changingRule &&
                                rules.length < capacity
                            ? () => _changeRule()
                            : null,
                        child: const Text('添加 LSM 规则'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                PanelCard(
                  title: 'chattr 保护路径',
                  trailing: Text(
                    '${entries.length} 个',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                  child: entries.isEmpty
                      ? Text(
                          ready ? '尚未保护任何路径。' : '当前主机不具备 chattr，入口不会展示无效开关。',
                          style: TextStyle(
                            fontSize: 11.5,
                            color: hampanelMuted,
                          ),
                        )
                      : Column(
                          children: [
                            for (final entry in entries)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Row(
                                  children: [
                                    Icon(
                                      entry['immutable'] == true
                                          ? Icons.lock
                                          : Icons.lock_open,
                                      size: 16,
                                      color: entry['immutable'] == true
                                          ? hampanelAccent
                                          : hampanelMuted,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            entry['path'] as String? ?? '',
                                            style: monospace.copyWith(
                                              fontSize: 11.5,
                                            ),
                                            maxLines: 2,
                                            overflow: TextOverflow.ellipsis,
                                          ),
                                          Text(
                                            '${entry['attributes'] ?? ''}'
                                            '${entry['present'] == false ? ' · 路径已不存在' : ''}',
                                            style: TextStyle(
                                              fontSize: 10.5,
                                              color: hampanelMuted,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    IconButton(
                                      tooltip: '解除保护',
                                      visualDensity: VisualDensity.compact,
                                      onPressed: () => _remove(
                                        entry['path'] as String? ?? '',
                                      ),
                                      icon: const Icon(
                                        Icons.lock_open,
                                        size: 18,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                ),
              ],
            ),
    );
  }
}
