import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/fail2ban.dart';
import '../../core/models/software.dart';
import '../../core/session.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';

class SoftwarePage extends StatefulWidget {
  const SoftwarePage({super.key});

  @override
  State<SoftwarePage> createState() => _SoftwarePageState();
}

class _SoftwarePageState extends State<SoftwarePage> {
  final _maxretryController = TextEditingController(text: '5');
  final _bantimeController = TextEditingController(text: '3600');
  final _findtimeController = TextEditingController(text: '600');

  List<SoftwareItem> _items = const [];
  Fail2banStatus? _fail2ban;
  bool _loading = true;
  bool _f2bLoading = false;
  String? _error;
  String? _f2bError;
  String? _initializingId;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _maxretryController.dispose();
    _bantimeController.dispose();
    _findtimeController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/software');
      final map = json as Map<String, dynamic>;
      final items = ((map['items'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(SoftwareItem.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _items = items;
        _loading = false;
      });
      final fail2ban = items.where((item) => item.id == 'fail2ban').firstOrNull;
      if (fail2ban != null && fail2ban.initialized) {
        await _loadFail2ban();
      } else {
        setState(() => _fail2ban = null);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  Future<void> _loadFail2ban() async {
    setState(() {
      _f2bLoading = true;
      _f2bError = null;
    });
    try {
      final json = await _api.getJson('/api/v1/fail2ban');
      final status = Fail2banStatus.fromJson(json as Map<String, dynamic>);
      if (!mounted) return;
      setState(() {
        _fail2ban = status;
        _f2bLoading = false;
      });
      final jail = status.jails.isNotEmpty ? status.jails.first : null;
      if (jail != null) {
        if (_maxretryController.text.isEmpty) {
          _maxretryController.text = jail.maxretry.isEmpty
              ? '5'
              : jail.maxretry;
        }
        if (_bantimeController.text.isEmpty) {
          _bantimeController.text = jail.bantime.isEmpty
              ? '3600'
              : jail.bantime;
        }
        if (_findtimeController.text.isEmpty) {
          _findtimeController.text = jail.findtime.isEmpty
              ? '600'
              : jail.findtime;
        }
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _f2bError = describeError(error);
        _f2bLoading = false;
      });
    }
  }

  Future<void> _initialize(SoftwareItem item) async {
    final confirmed = await _showInitializeDialog(item);
    if (!confirmed) return;
    setState(() => _initializingId = item.id);
    try {
      final json = await _api.postJson(
        '/api/v1/software/${item.id}/initialize',
        const <String, dynamic>{},
      );
      final map = json as Map<String, dynamic>? ?? const {};
      if (!mounted) return;
      await showOutputDialog(
        context,
        map['ok'] == true ? '${item.name} 初始化完成' : '${item.name} 初始化未完成',
        map['output'] as String? ?? '',
      );
      await _load();
    } catch (error) {
      _toast(describeError(error));
    } finally {
      if (mounted) setState(() => _initializingId = null);
    }
  }

  Future<bool> _showInitializeDialog(SoftwareItem item) async {
    var accepted = false;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text('初始化 ${item.name}？'),
          content: DialogBody(
            maxWidth: 540,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '初始化会执行以下操作：',
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 10),
                _bullet('停止当前 ${item.service} 服务（会短暂中断）'),
                _bullet('写入 Hampanel 托管配置，不覆盖系统原始配置文件'),
                _bullet('启动服务并设置开机自启；校验失败时自动回滚'),
                const SizedBox(height: 12),
                Text(
                  '如果服务由其他面板或手工配置管理，初始化后请使用 Hampanel 进行后续修改。',
                  style: TextStyle(
                    fontSize: 11.5,
                    color: hampanelMuted,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 12),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: accepted,
                  onChanged: (value) =>
                      setDialogState(() => accepted = value ?? false),
                  title: const Text(
                    '我明白服务会短暂中断',
                    style: TextStyle(fontSize: 12.5),
                  ),
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
              onPressed: accepted ? () => Navigator.pop(context, true) : null,
              child: const Text('确认初始化'),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }

  Widget _bullet(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.only(top: 5),
            child: Icon(Icons.circle, size: 5, color: hampanelAccent),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _ban(Fail2banJail? jail) async {
    final jails = _fail2ban?.jails ?? const <Fail2banJail>[];
    if (jails.isEmpty) return;
    final ipController = TextEditingController();
    String selectedJail = jail?.name ?? jails.first.name;
    final submitted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('封禁 IP'),
          content: DialogBody(
            maxWidth: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                DropdownButtonFormField<String>(
                  initialValue: selectedJail,
                  decoration: const InputDecoration(labelText: 'Jail'),
                  items: [
                    for (final item in jails)
                      DropdownMenuItem(
                        value: item.name,
                        child: Text(item.name),
                      ),
                  ],
                  onChanged: (value) {
                    if (value != null) {
                      setDialogState(() => selectedJail = value);
                    }
                  },
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: ipController,
                  decoration: const InputDecoration(
                    labelText: 'IP 地址',
                    hintText: '203.0.113.10 或 2001:db8::1',
                  ),
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
              child: const Text('封禁'),
            ),
          ],
        ),
      ),
    );

    if (submitted == true) {
      await _runFail2ban('/api/v1/fail2ban/ban', {
        'jail': selectedJail,
        'ip': ipController.text.trim(),
      });
    }
    ipController.dispose();
  }

  Future<void> _unban(Fail2banJail jail, String ip) async {
    await _runFail2ban('/api/v1/fail2ban/unban', {'jail': jail.name, 'ip': ip});
  }

  Future<void> _saveLimits() async {
    final maxretry = int.tryParse(_maxretryController.text.trim());
    final bantime = int.tryParse(_bantimeController.text.trim());
    final findtime = int.tryParse(_findtimeController.text.trim());
    if (maxretry == null || bantime == null || findtime == null) {
      _toast('阈值必须是整数');
      return;
    }
    await _runFail2ban('/api/v1/fail2ban/config', {
      'maxretry': maxretry,
      'bantime': bantime,
      'findtime': findtime,
    });
  }

  Future<void> _runFail2ban(String path, Map<String, dynamic> body) async {
    try {
      final json = await _api.postJson(path, body);
      final map = json as Map<String, dynamic>? ?? const {};
      if (map['ok'] == false) {
        if (!mounted) return;
        await showOutputDialog(
          context,
          '操作未完成',
          map['output'] as String? ?? '',
        );
      } else {
        _toast(map['output'] as String? ?? '操作完成');
      }
      await _loadFail2ban();
    } catch (error) {
      _toast(describeError(error));
    }
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
          title: '软件管理',
          subtitle: '已安装软件的状态、初始化与托管管理',
          actions: [
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
                    for (final item in _items) ...[
                      _softwareCard(
                        item,
                        extra: item.id == 'fail2ban' && item.initialized
                            ? _fail2banSection()
                            : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  Widget _softwareCard(SoftwareItem item, {Widget? extra}) {
    final initializing = _initializingId == item.id;
    return PanelCard(
      title: item.name,
      trailing: StatusPill(
        text: !item.installed
            ? '未安装'
            : item.needsInitialization
            ? '待初始化'
            : item.active
            ? '运行中'
            : '已托管',
        good: item.installed && !item.needsInitialization,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.description,
            style: TextStyle(fontSize: 12, color: hampanelMuted, height: 1.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _meta('版本', item.version.isEmpty ? '-' : item.version),
              _meta('服务', item.service.isEmpty ? '-' : item.service),
              _meta('托管', item.initialized ? '已初始化' : '未初始化'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Text(
                  item.manageHint,
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                ),
              ),
              if (!item.installed)
                Text(
                  '请先在「应用商店 → 系统工具」安装',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                )
              else if (item.needsInitialization)
                FilledButton.icon(
                  onPressed: initializing ? null : () => _initialize(item),
                  icon: initializing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.settings_suggest_outlined, size: 16),
                  label: Text(item.initialized ? '重新初始化' : '初始化'),
                ),
            ],
          ),
          if (extra != null) ...[
            const SizedBox(height: 14),
            Container(height: 1, color: hampanelBorder),
            const SizedBox(height: 14),
            extra,
          ],
        ],
      ),
    );
  }

  Widget _meta(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: TextStyle(fontSize: 11, color: hampanelMuted)),
        SelectableText(value, style: monospace.copyWith(fontSize: 11)),
      ],
    );
  }

  Widget _fail2banSection() {
    if (_f2bLoading && _fail2ban == null) return const LoadingView();
    if (_f2bError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: ErrorBanner(message: _f2bError!, onRetry: _loadFail2ban),
      );
    }
    final status = _fail2ban;
    if (status == null) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '封禁管理',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            StatusPill(
              text: status.active ? '运行中' : '未运行',
              good: status.active,
            ),
            const Spacer(),
            OutlinedButton.icon(
              onPressed: _loadFail2ban,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        if (status.message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              status.message,
              style: TextStyle(fontSize: 11.5, color: hampanelDanger),
            ),
          ),
        if (status.jails.isEmpty)
          Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '当前没有启用的 jail。',
              style: TextStyle(fontSize: 12, color: hampanelMuted),
            ),
          )
        else
          for (final jail in status.jails) _jailCard(jail),
        const SizedBox(height: 12),
        Row(
          children: [
            const Expanded(
              child: Text(
                'DEFAULT 阈值',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
              ),
            ),
            FilledButton.icon(
              onPressed: _saveLimits,
              icon: const Icon(Icons.save_outlined, size: 16),
              label: const Text('保存阈值'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FormRow(
          children: [
            TextField(
              controller: _maxretryController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'maxretry'),
            ),
            TextField(
              controller: _bantimeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'bantime（秒）'),
            ),
            TextField(
              controller: _findtimeController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'findtime（秒）'),
            ),
          ],
        ),
      ],
    );
  }

  Widget _jailCard(Fail2banJail jail) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: hampanelSurfaceAlt,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: hampanelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.gavel_outlined, size: 17, color: hampanelAccent),
              const SizedBox(width: 8),
              Text(
                jail.name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const Spacer(),
              Text(
                '当前封禁 ${jail.currentlyBanned} / 累计 ${jail.totalBanned}',
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
              const SizedBox(width: 10),
              OutlinedButton.icon(
                onPressed: () => _ban(jail),
                icon: const Icon(Icons.block, size: 15),
                label: const Text('封禁 IP'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'maxretry ${jail.maxretry} · bantime ${jail.bantime}s · findtime ${jail.findtime}s',
            style: monospace.copyWith(fontSize: 11, color: hampanelMuted),
          ),
          if (jail.bannedIps.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final ip in jail.bannedIps)
                  InputChip(
                    label: Text(ip, style: monospace.copyWith(fontSize: 11)),
                    onDeleted: () => _unban(jail, ip),
                    deleteIcon: const Icon(Icons.close, size: 14),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
