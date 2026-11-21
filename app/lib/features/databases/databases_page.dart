import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/native_files.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import '../terminal/terminal_page.dart';
import 'database_dialogs.dart';

const _root = '/api/v1/databases/instances';
typedef _Json = Map<String, dynamic>;

class DatabasesPage extends StatefulWidget {
  const DatabasesPage({super.key});

  @override
  State<DatabasesPage> createState() => _DatabasesPageState();
}

class _DatabasesPageState extends State<DatabasesPage> {
  late ApiClient api;
  Future<_Json>? request;
  _Json? instance;
  String? database;
  bool busy = false;

  /// Empty means "show every engine"; otherwise only that engine's instances
  /// are listed. Mirrors the runtimes page, where the left rail switches the
  /// category instead of everything piling into one list.
  String _engineFilter = '';

  String get instancePath =>
      '$_root/${Uri.encodeComponent(instance!['id'].toString())}';
  String get dbPath =>
      '$instancePath/databases/${Uri.encodeComponent(database!)}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    api = PanelScope.of(context).api;
    request ??= load();
  }

  Future<_Json> load() async {
    if (instance == null) return await api.getJson(_root) as _Json;
    if (database == null) {
      return await api.getJson('$instancePath/overview') as _Json;
    }
    final results = await Future.wait([
      api.getJson('$dbPath/tables'),
      api.getJson('$instancePath/backups'),
    ]);
    return {
      'tables': results.first['tables'],
      'backups': results.last['items'],
    };
  }

  bool get isRedis => instance?['engine'] == 'redis';

  void refresh() => setState(() => request = load());
  void navigate(_Json? target, [String? name]) {
    instance = target;
    database = name;
    setState(() {
      if (!isRedis) request = load();
    });
  }

  Future<void> run(Future<void> Function() work) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      await work();
    } catch (e) {
      if (mounted) notice('操作失败：$e');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  void notice(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Future<void> registration([_Json? item]) async {
    final body = await databaseDialog(
      context,
      item == null ? '登记实例' : '编辑实例',
      '保存',
      ['name', 'host', 'port', 'user', 'password', 'container', 'socket'],
      instance: true,
      editing: item != null,
      initial: item ?? {},
      api: api,
    );
    if (body == null || !mounted) return;
    if (item == null) {
      await api.postJson(_root, body);
    } else {
      await api.putJson(
        '$_root/${Uri.encodeComponent(item['id'].toString())}',
        body,
      );
    }
    if (mounted) refresh();
  }

  Future<void> unregister(_Json item) async {
    final name = item['name'] as String;
    final ok = await databaseDialog(
      context,
      '移除实例登记',
      '移除',
      ['confirm'],
      confirm: name,
      message: '仅移除连接信息，不删除数据库。请输入「$name」。',
    );
    if (ok == null || !mounted) return;
    await api.deleteJson(
      '$_root/${Uri.encodeComponent(item['id'].toString())}',
    );
    if (mounted) refresh();
  }

  Future<void> create(String title, String route, List<String> fields) async {
    final body = await databaseDialog(context, title, title, fields);
    if (body == null || !mounted) return;
    await api.postJson('$instancePath/$route', body);
    if (mounted) {
      notice('$title：已完成');
      refresh();
    }
  }

  Future<void> backup() async {
    final result = await api.postJson(
      '$dbPath/backup',
      {},
      timeout: const Duration(minutes: 15),
    );
    if (mounted) {
      notice('已备份：${result['name']}');
      refresh();
    }
  }

  Future<void> destructive([String? source]) async {
    final name = database!;
    final verb = source == null ? '删除数据库' : '恢复备份';
    final ok = await databaseDialog(
      context,
      verb,
      verb,
      ['confirm'],
      confirm: name,
      message:
          '${source == null ? '将永久删除数据库' : '将从「$source」覆盖数据库内容'}。请输入「$name」。',
    );
    if (ok == null || !mounted) return;
    if (source == null) {
      await api.deleteJson(dbPath, query: {'confirm': name});
      if (mounted) navigate(instance);
    } else {
      await api.postJson('$dbPath/restore', {
        'backup': source,
        'confirm': name,
      }, timeout: const Duration(minutes: 15));
      if (mounted) {
        notice('已恢复：$name');
        refresh();
      }
    }
  }

  Future<void> download(String name) async {
    final url = '$instancePath/backups/${Uri.encodeComponent(name)}/download';
    if (NativeFiles.supported) {
      final bytes = await api.downloadToBytes(url, {});
      if (!mounted || !await NativeFiles.save(name, bytes)) return;
    } else {
      final body = await databaseDialog(context, '下载备份', '保存', [
        'path',
      ], message: '为「$name」选择新的本地文件路径。');
      if (body == null || !mounted) return;
      final file = File(body['path'] as String);
      if (!file.isAbsolute) throw const FormatException('请输入绝对路径');
      await file.create(exclusive: true);
      try {
        await api.downloadToFile(url, {}, file.path);
      } catch (_) {
        await file.delete();
        rethrow;
      }
    }
    if (mounted) notice('备份已保存');
  }

  Widget action(String label, Future<void> Function() fn) => OutlinedButton(
    onPressed: busy ? null : () => run(fn),
    child: Text(label),
  );
  Widget heading(String label) => Padding(
    padding: const EdgeInsets.only(top: 20, bottom: 8),
    child: Text(label, style: Theme.of(context).textTheme.titleMedium),
  );

  List<Widget> instances(_Json data) => [
    Align(
      alignment: AlignmentDirectional.centerStart,
      child: action('登记实例', () => registration()),
    ),
    if ((data['items'] as List).isEmpty)
      const ListTile(title: Text('暂无实例，请先登记数据库连接。'))
    else if (_engineFilter.isNotEmpty &&
        !(data['items'] as List).any((item) => item['engine'] == _engineFilter))
      ListTile(
        title: Text(
          '暂无 ${engineLabels[_engineFilter] ?? _engineFilter} 实例；可切换到「全部」查看其它引擎。',
        ),
      ),
    for (final item in (data['items'] as List).cast<_Json>())
      if (_engineFilter.isEmpty || item['engine'] == _engineFilter)
      ListTile(
        leading: const Icon(Icons.storage),
        title: Text(item['name']),
        subtitle: Text(
          '${engineLabels[item['engine']]} · ${modeLabels[item['mode']]} · ${item['mode'] == 'host' ? '${item['host']}:${item['port']}' : item['container']}',
        ),
        onTap: busy ? null : () => navigate(item),
        trailing: PopupMenuButton<String>(
          enabled: !busy,
          onSelected: (v) =>
              run(() => v == 'edit' ? registration(item) : unregister(item)),
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'edit', child: Text('编辑实例')),
            PopupMenuItem(value: 'remove', child: Text('移除登记')),
          ],
        ),
      ),
  ];

  List<Widget> overview(_Json data) => [
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        action('创建数据库', () => create('创建数据库', 'databases', ['name'])),
        action('创建账号', () => create('创建账号', 'users', ['name', 'password'])),
        action(
          '重置管理账号密码',
          () => create('重置 ${instance!['user']} 的密码', 'password', ['password']),
        ),
      ],
    ),
    heading('数据库'),
    if ((data['databases'] as List).isEmpty) const Text('暂无数据库'),
    for (final name in data['databases'] as List)
      ListTile(
        title: Text(name),
        trailing: const Icon(Icons.chevron_right),
        onTap: busy ? null : () => navigate(instance, name),
      ),
    heading('实例账号'),
    if ((data['users'] as List).isEmpty) const Text('暂无账号'),
    for (final user in data['users'] as List) ListTile(title: Text(user)),
  ];

  List<Widget> details(_Json data) {
    final backups = (data['backups'] as List).cast<_Json>().where(
      (b) => b['database'] == database,
    );
    return [
      Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          action('创建备份', backup),
          action('删除数据库', () => destructive()),
        ],
      ),
      heading(instance?['engine'] == 'mongo' ? '集合' : '表'),
      if ((data['tables'] as List).isEmpty)
        Text(instance?['engine'] == 'mongo' ? '暂无集合' : '暂无表'),
      for (final table in data['tables'] as List) ListTile(title: Text(table)),
      heading('备份'),
      if (backups.isEmpty) const Text('此数据库暂无备份'),
      for (final b in backups)
        ListTile(
          title: Text(b['name']),
          subtitle: Text('${b['created_at']} · ${b['size']} B'),
          trailing: PopupMenuButton<String>(
            enabled: !busy,
            onSelected: (v) => run(
              () => v == 'download'
                  ? download(b['name'])
                  : destructive(b['name']),
            ),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'download', child: Text('下载')),
              PopupMenuItem(value: 'restore', child: Text('恢复备份')),
            ],
          ),
        ),
    ];
  }

  static const _engineOrder = [
    'mysql',
    'mariadb',
    'postgres',
    'mongo',
    'redis',
  ];

  List<String> get _engineLabels => [
    '全部',
    for (final engine in _engineOrder) engineLabels[engine] ?? engine,
  ];

  int get _engineIndex {
    if (_engineFilter.isEmpty) return 0;
    final index = _engineOrder.indexOf(_engineFilter);
    return index < 0 ? 0 : index + 1;
  }

  void _selectEngine(int index) {
    setState(() {
      _engineFilter = index == 0 ? '' : _engineOrder[index - 1];
    });
  }

  Widget _withEngineNav(Widget list) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final narrow = constraints.maxWidth < 760;
        if (narrow) {
          return Column(
            children: [
              Expanded(child: list),
              Container(
                decoration: BoxDecoration(
                  border: Border(
                    top: BorderSide(color: hampanelBorder),
                  ),
                ),
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
                child: SafeArea(
                  top: false,
                  child: SubNavMenu(
                    items: _engineLabels,
                    index: _engineIndex,
                    onChanged: _selectEngine,
                  ),
                ),
              ),
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SubNav(
              items: _engineLabels,
              index: _engineIndex,
              onChanged: _selectEngine,
            ),
            Expanded(child: list),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      PageHeader(
        title: database ?? instance?['name'] ?? '数据库',
        subtitle: database != null
            ? '${instance!['name']} / $database'
            : instance == null
            ? '数据库实例'
            : isRedis
            ? 'Redis 命令行'
            : '数据库与实例账号',
        actions: [
          if (instance != null)
            IconButton(
              tooltip: '返回上一级',
              icon: const Icon(Icons.arrow_back),
              onPressed: busy
                  ? null
                  : () => navigate(database == null ? null : instance),
            ),
          if (!isRedis) PageRefreshButton(onPressed: busy ? null : refresh),
        ],
      ),
      if (busy) const LinearProgressIndicator(),
      if (isRedis)
        Expanded(child: TerminalPage(redisId: instance!['id'].toString()))
      else
        Expanded(
          child: FutureBuilder<_Json>(
            future: request,
            builder: (context, state) {
              if (state.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (state.hasError) {
                return ListView(
                  padding: pageContentPadding(context),
                  children: [
                    Text('读取失败：${state.error}'),
                    TextButton(onPressed: refresh, child: const Text('重试')),
                  ],
                );
              }
              final data = state.requireData;
              final list = ListView(
                key: ValueKey((instance?['id'], database, _engineFilter)),
                padding: pageContentPadding(context),
                children: instance == null
                    ? instances(data)
                    : database == null
                    ? overview(data)
                    : details(data),
              );
              // The engine rail only makes sense while browsing instances; once
              // an instance is open the page drills into its contents.
              return instance == null ? _withEngineNav(list) : list;
            },
          ),
        ),
    ],
  );
}
