import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/ssh_logs.dart';
import '../../core/models/ssh_status.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';

class SshPage extends StatefulWidget {
  const SshPage({super.key});

  @override
  State<SshPage> createState() => _SshPageState();
}

class _SshPageState extends State<SshPage> {
  final _portController = TextEditingController();
  final _userController = TextEditingController(text: 'root');

  SshStatus? _status;
  List<SshKey> _keys = const [];
  bool _loading = true;
  bool _keysLoading = false;
  String? _error;
  String? _keysError;

  String _rootLogin = 'prohibit-password';
  bool _passwordAuth = true;
  bool _pubkeyAuth = true;
  bool _busy = false;

  SshLoggingStatus? _logging;
  SshLogs? _sshLogs;
  bool _logsLoading = false;
  String? _logsError;
  String _logMode = 'syslog';
  String _logSource = 'journal';
  int _logLines = 200;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _loadStatus();
  }

  @override
  void dispose() {
    _portController.dispose();
    _userController.dispose();
    super.dispose();
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/ssh');
      final status = SshStatus.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _status = status;
        _loading = false;
        _portController.text = status.port.isEmpty ? '22' : status.port;
        _rootLogin = _allowedRootLogin(status.permitRootLogin);
        _passwordAuth = status.passwordAuthentication != 'no';
        _pubkeyAuth = status.pubkeyAuthentication != 'no';
        if (status.currentUser.isNotEmpty) {
          _userController.text = status.currentUser;
        }
      });
      if (status.available) {
        await _loadKeys();
        await _loadLogging();
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  String _allowedRootLogin(String value) {
    const allowed = {'yes', 'no', 'prohibit-password', 'forced-commands-only'};
    return allowed.contains(value) ? value : 'prohibit-password';
  }

  Future<void> _loadKeys() async {
    final user = _userController.text.trim();
    if (user.isEmpty) return;
    setState(() {
      _keysLoading = true;
      _keysError = null;
    });
    try {
      final json = await _api.getJson(
        '/api/v1/ssh/keys',
        query: {'user': user},
      );
      final map = json as Map<String, dynamic>;
      final keys = ((map['keys'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SshKey.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _keys = keys;
        _keysLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _keysError = describeError(error);
        _keysLoading = false;
      });
    }
  }

  Future<void> _save() async {
    final port = int.tryParse(_portController.text.trim());
    if (port == null || port < 1 || port > 65535) {
      _toast('端口必须是 1-65535');
      return;
    }
    final ok = await confirmDialog(
      context,
      title: '应用 SSH 配置?',
      message:
          '配置会先通过 sshd -t 校验，失败时自动回滚。'
          '修改端口后请确认防火墙放行，并保持当前会话不要断开。',
      confirmLabel: '保存并重载',
    );
    if (!ok) return;

    setState(() => _busy = true);
    try {
      final json = await _api.postJson('/api/v1/ssh/config', {
        'port': port,
        'permit_root_login': _rootLogin,
        'password_authentication': _passwordAuth,
        'pubkey_authentication': _pubkeyAuth,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(
          context,
          'SSH 配置未应用',
          map['output'] as String? ?? '',
        );
      } else {
        await showOutputDialog(
          context,
          'SSH 配置已应用',
          map['output'] as String? ?? '配置已重载',
        );
      }
      await _loadStatus();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addKey() async {
    final keyController = TextEditingController();
    final commentController = TextEditingController();
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加 SSH 公钥'),
        content: SizedBox(
          width: 620,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: keyController,
                maxLines: 4,
                decoration: const InputDecoration(
                  labelText: '公钥',
                  hintText: 'ssh-ed25519 AAAA... user@host',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: commentController,
                decoration: const InputDecoration(labelText: '备注（可选）'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('添加'),
          ),
        ],
      ),
    );

    if (submitted == true) {
      try {
        final json = await _api.postJson('/api/v1/ssh/keys', {
          'user': _userController.text.trim(),
          'key': keyController.text.trim(),
          'comment': commentController.text.trim(),
        });
        final map = json as Map<String, dynamic>? ?? const {};
        _toast(map['output'] as String? ?? '公钥已添加');
        await _loadKeys();
      } catch (error) {
        _toast(describeError(error));
      }
    }
    keyController.dispose();
    commentController.dispose();
  }

  Future<void> _removeKey(SshKey key) async {
    final ok = await confirmDialog(
      context,
      title: '删除公钥?',
      message: '将从 ${_userController.text.trim()} 的 authorized_keys 中移除该公钥。',
      confirmLabel: '删除',
      danger: true,
    );
    if (!ok) return;
    try {
      final json = await _api.postJson('/api/v1/ssh/keys/delete', {
        'user': _userController.text.trim(),
        'index': key.index,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      _toast(map['output'] as String? ?? '公钥已删除');
      await _loadKeys();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Future<void> _loadLogging() async {
    try {
      final json = await _api.getJson('/api/v1/ssh/logging');
      final logging = SshLoggingStatus.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      var source = 'file';
      if (logging.mode == 'file') {
        source = 'file';
      } else if (logging.journalAvailable) {
        source = 'journal';
      } else if (logging.authLogPath.isNotEmpty) {
        source = 'auth';
      }
      setState(() {
        _logging = logging;
        _logMode = logging.mode;
        _logSource = source;
        _logsError = null;
      });
      await _loadLogs();
    } catch (error) {
      if (!mounted) return;
      setState(() => _logsError = describeError(error));
    }
  }

  Future<void> _loadLogs() async {
    setState(() {
      _logsLoading = true;
      _logsError = null;
    });
    try {
      final json = await _api.getJson(
        '/api/v1/ssh/logs',
        query: {'source': _logSource, 'lines': '$_logLines'},
      );
      final logs = SshLogs.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _sshLogs = logs;
        _logsLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _logsError = describeError(error);
        _logsLoading = false;
      });
    }
  }

  Future<void> _applyLogMode() async {
    final logging = _logging;
    if (logging == null) return;
    if (_logMode == logging.mode) {
      _toast('已经是当前日志记录方式');
      return;
    }
    if (_logMode == 'file' && !logging.rsyslogAvailable) {
      _toast('请先在应用商店安装 rsyslog');
      return;
    }

    final ok = await confirmDialog(
      context,
      title: '切换 SSH 日志记录方式？',
      message: _logMode == 'file'
          ? '将写入 rsyslog 配置并把 sshd 日志额外记录到 ${logging.file}。'
                'syslog 管线保留，fail2ban 不受影响；只需重载 rsyslog。'
          : '将移除 Hampanel 管理的 rsyslog 文件日志配置并重载 rsyslog，'
                'ssh 日志继续记录到 syslog/journald。',
      confirmLabel: '应用',
    );
    if (!ok) return;

    try {
      final json = await _api.postJson('/api/v1/ssh/logging', {
        'mode': _logMode,
      });
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      if (map['ok'] == false) {
        await showOutputDialog(context, '切换失败', map['output'] as String? ?? '');
      } else {
        _toast(map['output'] as String? ?? '日志记录方式已更新');
      }
      await _loadLogging();
    } catch (error) {
      _toast(describeError(error));
    }
  }

  Widget _loggingCard() {
    final logging = _logging;
    return PanelCard(
      title: '日志记录',
      trailing: IconButton(
        tooltip: '刷新',
        onPressed: _loadLogging,
        icon: const Icon(Icons.refresh, size: 18),
      ),
      child: logging == null
          ? const LoadingView()
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 260,
                      child: DropdownButtonFormField<String>(
                        key: ValueKey(_logMode),
                        initialValue: _logMode,
                        decoration: const InputDecoration(labelText: '记录方式'),
                        items: const [
                          DropdownMenuItem(
                            value: 'syslog',
                            child: Text('syslog / journald'),
                          ),
                          DropdownMenuItem(
                            value: 'file',
                            child: Text('传统文件（rsyslog）'),
                          ),
                        ],
                        onChanged: (value) {
                          if (value != null) setState(() => _logMode = value);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: _applyLogMode,
                      child: const Text('应用'),
                    ),
                  ],
                ),
                if (logging.mode == 'file')
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      '当前文件: ${logging.file}',
                      style: monospace.copyWith(fontSize: 11.5),
                    ),
                  ),
                if (!logging.rsyslogAvailable)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      '未检测到 rsyslog，文件模式不可用；可在「应用商店 → 系统工具」安装 rsyslog。',
                      style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                    ),
                  ),
                if (logging.message.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      logging.message,
                      style: const TextStyle(
                        fontSize: 11.5,
                        color: hampanelMuted,
                      ),
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _logsCard() {
    final logging = _logging;
    final sources = <String>[
      if (logging?.journalAvailable == true) 'journal',
      if (logging?.authLogPath.isNotEmpty == true) 'auth',
      'file',
    ];
    if (!sources.contains(_logSource)) {
      _logSource = sources.first;
    }
    return PanelCard(
      title: 'SSH 日志',
      trailing: Wrap(
        spacing: 8,
        children: [
          DropdownButton<int>(
            value: _logLines,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 100, child: Text('100 行')),
              DropdownMenuItem(value: 300, child: Text('300 行')),
              DropdownMenuItem(value: 1000, child: Text('1000 行')),
              DropdownMenuItem(value: 2000, child: Text('2000 行')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _logLines = value);
              _loadLogs();
            },
          ),
          OutlinedButton.icon(
            onPressed: _logsLoading ? null : _loadLogs,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新'),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 280,
            child: DropdownButtonFormField<String>(
              key: ValueKey(_logSource),
              initialValue: _logSource,
              decoration: const InputDecoration(labelText: '日志来源'),
              items: [
                if (sources.contains('journal'))
                  const DropdownMenuItem(
                    value: 'journal',
                    child: Text('journald'),
                  ),
                if (sources.contains('auth'))
                  DropdownMenuItem(
                    value: 'auth',
                    child: Text(
                      logging?.authLogPath.isNotEmpty == true
                          ? logging!.authLogPath
                          : 'auth log',
                    ),
                  ),
                const DropdownMenuItem(value: 'file', child: Text('文件日志')),
              ],
              onChanged: (value) {
                if (value == null) return;
                setState(() => _logSource = value);
                _loadLogs();
              },
            ),
          ),
          if (_sshLogs != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '${_sshLogs!.path}${_sshLogs!.truncated ? '（仅显示尾部）' : ''}',
                style: monospace.copyWith(fontSize: 11, color: hampanelMuted),
              ),
            ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            height: 340,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF070C10),
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: hampanelBorder),
            ),
            child: _logsLoading
                ? const LoadingView()
                : _logsError != null
                ? SingleChildScrollView(
                    child: Text(
                      _logsError!,
                      style: const TextStyle(
                        fontSize: 12,
                        color: hampanelDanger,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: SelectableText(
                      (_sshLogs?.content ?? '').isEmpty
                          ? '暂无日志。'
                          : _sshLogs!.content,
                      style: monospace.copyWith(fontSize: 11.5),
                    ),
                  ),
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
    final status = _status;
    return Column(
      children: [
        PageHeader(
          title: 'SSH 管理',
          subtitle: 'sshd 状态、安全配置与 authorized_keys',
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _loading ? null : _loadStatus,
              icon: const Icon(Icons.refresh, size: 20),
            ),
          ],
        ),
        Expanded(
          child: _loading
              ? const LoadingView()
              : _error != null
              ? SingleChildScrollView(
                  child: ErrorBanner(message: _error!, onRetry: _loadStatus),
                )
              : status == null || !status.available
              ? EmptyState(
                  icon: Icons.vpn_key_outlined,
                  title: 'SSH 管理不可用',
                  message: status?.message.isNotEmpty == true
                      ? status!.message
                      : '未检测到 sshd，或当前平台不支持该功能。',
                  action: OutlinedButton(
                    onPressed: _loadStatus,
                    child: const Text('重新检测'),
                  ),
                )
              : _content(status),
        ),
      ],
    );
  }

  Widget _content(SshStatus status) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
      children: [
        PanelCard(
          title: '运行状态',
          trailing: StatusPill(
            text: status.active ? '运行中' : '未运行',
            good: status.active,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _row(
                '服务',
                status.service.isEmpty ? '-' : '${status.service}.service',
              ),
              _row('版本', status.version.isEmpty ? '-' : status.version),
              _row(
                '当前用户',
                status.currentUser.isEmpty ? '-' : status.currentUser,
              ),
              _row(
                '托管文件',
                status.dropIn.isEmpty
                    ? '使用 sshd_config Include'
                    : status.dropIn,
              ),
              if (status.message.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  status.message,
                  style: const TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 14),
        PanelCard(
          title: '生效配置',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  SizedBox(
                    width: 150,
                    child: TextField(
                      controller: _portController,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'SSH 端口'),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _rootLogin,
                      decoration: const InputDecoration(
                        labelText: 'PermitRootLogin',
                      ),
                      items: const [
                        DropdownMenuItem(
                          value: 'prohibit-password',
                          child: Text('prohibit-password'),
                        ),
                        DropdownMenuItem(value: 'yes', child: Text('yes')),
                        DropdownMenuItem(value: 'no', child: Text('no')),
                        DropdownMenuItem(
                          value: 'forced-commands-only',
                          child: Text('forced-commands-only'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) setState(() => _rootLogin = value);
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('密码登录', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'PasswordAuthentication',
                  style: TextStyle(fontSize: 11),
                ),
                value: _passwordAuth,
                onChanged: (value) => setState(() => _passwordAuth = value),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('公钥登录', style: TextStyle(fontSize: 13)),
                subtitle: const Text(
                  'PubkeyAuthentication',
                  style: TextStyle(fontSize: 11),
                ),
                value: _pubkeyAuth,
                onChanged: (value) => setState(() => _pubkeyAuth = value),
              ),
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: FilledButton.icon(
                  onPressed: _busy ? null : _save,
                  icon: _busy
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.save_outlined, size: 16),
                  label: const Text('保存并重载'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        _loggingCard(),
        const SizedBox(height: 14),
        _logsCard(),
        const SizedBox(height: 14),
        PanelCard(
          title: 'Authorized Keys',
          trailing: Wrap(
            spacing: 8,
            children: [
              OutlinedButton.icon(
                onPressed: _keysLoading ? null : _loadKeys,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新'),
              ),
              FilledButton.icon(
                onPressed: _addKey,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加公钥'),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 260,
                child: TextField(
                  controller: _userController,
                  decoration: const InputDecoration(labelText: '用户'),
                  onSubmitted: (_) => _loadKeys(),
                ),
              ),
              const SizedBox(height: 12),
              if (_keysLoading)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 16),
                  child: LoadingView(),
                )
              else if (_keysError != null)
                Text(
                  _keysError!,
                  style: const TextStyle(fontSize: 12, color: hampanelDanger),
                )
              else if (_keys.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    '该用户尚未配置公钥。',
                    style: TextStyle(fontSize: 12, color: hampanelMuted),
                  ),
                )
              else
                for (final key in _keys)
                  Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    decoration: BoxDecoration(
                      color: hampanelSurfaceAlt,
                      borderRadius: BorderRadius.circular(3),
                      border: Border.all(color: hampanelBorder),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.key, size: 17, color: hampanelAccent),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                key.comment.isEmpty
                                    ? key.keyType
                                    : '${key.keyType} · ${key.comment}',
                                style: const TextStyle(fontSize: 12.5),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                key.key,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: monospace.copyWith(
                                  fontSize: 11,
                                  color: hampanelMuted,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '删除',
                          onPressed: () => _removeKey(key),
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

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: const TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: monospace.copyWith(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
