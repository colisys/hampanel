import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/fail2ban.dart';
import '../../core/models/software.dart';
import '../../core/session.dart';
import '../../ui/code_editor.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../store/deploy_dialog.dart';
import 'software_card.dart';

class SoftwarePage extends StatefulWidget {
  const SoftwarePage({super.key});

  @override
  State<SoftwarePage> createState() => _SoftwarePageState();
}

class _SoftwarePageState extends State<SoftwarePage>
    with SingleTickerProviderStateMixin {
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
  TabController? _tabs;

  ApiClient get _api => PanelScope.of(context).api;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _tabs?.dispose();
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
      final previousTabs = _tabs;
      final nextTabs = items.isEmpty
          ? null
          : TabController(length: items.length, vsync: this);
      setState(() {
        _tabs = nextTabs;
        _items = items;
        _loading = false;
      });
      if (previousTabs != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!identical(_tabs, previousTabs)) previousTabs.dispose();
        });
      }
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
    if (!mounted) return;
    setState(() => _initializingId = item.id);
    try {
      final center = PanelScope.of(context).tasks;
      final task = await center.submit(
        'software.initialize',
        title: '初始化 ${item.name}',
        params: {'id': item.id},
      );
      if (!mounted) return;
      _toast('已提交任务：${task.title}');
      unawaited(center.waitFor(task.id).then((_) {
        if (mounted) _load();
      }));
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

  Future<void> _showAllBanned(Fail2banJail jail) async {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${jail.name} 封禁 IP'),
        content: DialogBody(
          maxWidth: 520,
          maxHeight: 480,
          child: ListView.separated(
            itemCount: jail.bannedIps.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final ip = jail.bannedIps[index];
              return ListTile(
                dense: true,
                title: Text(ip, style: monospace.copyWith(fontSize: 12)),
                trailing: IconButton(
                  tooltip: '解封',
                  icon: const Icon(Icons.close, size: 16),
                  onPressed: () {
                    Navigator.pop(dialogContext);
                    _unban(jail, ip);
                  },
                ),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('关闭'),
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
    final tabs = _tabs;
    return Column(
      children: [
        PageHeader(
          title: '软件管理',
          actions: [
            PageRefreshButton(onPressed: _loading ? null : _load),
          ],
        ),
        if (_error != null)
          ErrorBanner(message: _error!, onRetry: _load),
        if (_loading)
          const Expanded(child: LoadingView())
        else if (_items.isEmpty)
          const Expanded(
            child: EmptyState(
              icon: Icons.apps_outlined,
              title: '没有可管理的软件',
              message: '请先在应用商店安装软件。',
            ),
          )
        else ...[
          TabBar(
            controller: tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            tabs: [for (final item in _items) Tab(text: item.name)],
          ),
          Expanded(
            child: TabBarView(
              controller: tabs,
              children: [for (final item in _items) _softwareTab(item)],
            ),
          ),
        ],
      ],
    );
  }

  Widget _softwareTab(SoftwareItem item) {
    return ListView(
      padding: pageContentPadding(context),
      children: [
        SoftwareCard(
          item: item,
          initializing: _initializingId == item.id,
          onInitialize: () => _initialize(item),
          configPaths: _configPaths(item.id),
          onEditConfig: _editConfig,
        ),
        if (item.id == 'fail2ban' && item.initialized) ...[
          const SizedBox(height: 12),
          _fail2banSection(),
        ],
      ],
    );
  }

  List<String> _configPaths(String id) {
    switch (id) {
      case 'fail2ban':
        return const ['/etc/fail2ban/jail.d/99-hampanel.local'];
      case 'clamav':
        return const [
          '/etc/clamav/clamd.conf',
          '/etc/clamav/freshclam.conf',
        ];
      case 'supervisord':
        return const ['/etc/supervisor/supervisord.conf'];
      case 'pure-ftpd':
        return const ['/etc/pure-ftpd/pure-ftpd.conf'];
      default:
        return const [];
    }
  }

  Future<void> _editConfig(String path) async {
    try {
      Map<String, dynamic> map = const {};
      try {
        final json = await _api.getJson(
          '/api/v1/files/content',
          query: {'path': path},
        );
        map = json as Map<String, dynamic>;
      } on ApiException catch (error) {
        if (error.status != 404) rethrow;
      }
      if ((map['encoding'] as String? ?? 'utf8') != 'utf8') {
        _toast('该文件不是 UTF-8 文本，暂不支持在线编辑');
        return;
      }
      if (!mounted) return;
      final edited = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => CodeEditorPage(
            title: path.split('/').last,
            initialText: map['content'] as String? ?? '',
            language: path.endsWith('.toml')
                ? CodeLanguage.toml
                : path.endsWith('.conf')
                ? CodeLanguage.properties
                : CodeLanguage.plain,
            api: _api,
            filePath: path,
          ),
        ),
      );
      if (edited == null) return;
      await _api.putJson('/api/v1/files/content', {
        'path': path,
        'content': edited,
      });
      _toast('已保存 $path');
    } catch (error) {
      _toast(describeError(error));
    }
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
    final wide = MediaQuery.sizeOf(context).width >= 900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        PanelCard(
          title: '封禁管理',
          trailing: OutlinedButton.icon(
            onPressed: _loadFail2ban,
            icon: const Icon(Icons.refresh, size: 16),
            label: const Text('刷新'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (status.message.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(
                    status.message,
                    style: TextStyle(fontSize: 11.5, color: hampanelDanger),
                  ),
                ),
              if (status.jails.isEmpty)
                Text(
                  '当前没有启用的 jail。',
                  style: TextStyle(fontSize: 12, color: hampanelMuted),
                )
              else
                for (final jail in status.jails) _jailCard(jail, wide: wide),
            ],
          ),
        ),
        const SizedBox(height: 12),
        PanelCard(
          title: 'DEFAULT 阈值',
          trailing: FilledButton.icon(
            onPressed: _saveLimits,
            icon: const Icon(Icons.save_outlined, size: 16),
            label: const Text('保存阈值'),
          ),
          child: FormRow(
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
        ),
      ],
    );
  }

  Widget _jailCard(Fail2banJail jail, {required bool wide}) {
    final all = jail.bannedIps.isEmpty
        ? null
        : TextButton(
            onPressed: () => _showAllBanned(jail),
            child: Text('查看全部 ${jail.bannedIps.length} 个封禁 IP'),
          );
    final ban = OutlinedButton.icon(
      onPressed: () => _ban(jail),
      icon: const Icon(Icons.block, size: 15),
      label: const Text('封禁 IP'),
    );
    final name = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Icon(Icons.gavel_outlined, size: 17, color: hampanelAccent),
        Text(
          jail.name,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (!wide) ban,
      ],
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: hampanelSurfaceAlt,
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: hampanelBorder),
      ),
      child: wide
          ? Row(
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
                if (all != null) ...[all, const SizedBox(width: 6)],
                ban,
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                name,
                if (all != null) ...[
                  const SizedBox(height: 6),
                  Align(alignment: Alignment.centerLeft, child: all),
                ],
              ],
            ),
    );
  }

}
