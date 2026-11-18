import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models/log_source.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/log_viewer.dart';
import '../../ui/widgets.dart';

class LogsPage extends StatefulWidget {
  const LogsPage({super.key});

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  List<LogSource> _sources = const [];
  String? _selected;
  String _content = '';
  bool _loading = true;
  bool _loadingContent = false;
  bool _truncated = false;
  String? _error;
  String? _path;
  int _lines = 200;

  @override
  void initState() {
    super.initState();
    _loadSources();
  }

  ApiClient get _api => PanelScope.of(context).api;

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await _api.getJson('/api/v1/logs/sources');
      final map = json as Map<String, dynamic>;
      final sources = ((map['sources'] as List<dynamic>?) ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(LogSource.fromJson)
          .toList();
      if (!mounted) return;
      setState(() {
        _sources = sources
            .where((source) => source.available)
            .toList(growable: false);
        if (_sources.isEmpty) {
          _selected = null;
        } else if (!_sources.any((source) => source.id == _selected)) {
          _selected = _sources.first.id;
        }
        _loading = false;
      });
      if (_selected != null) await _loadTail();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  Future<void> _loadTail() async {
    final selected = _selected;
    if (selected == null) return;
    setState(() => _loadingContent = true);
    try {
      final json = await _api.getJson(
        '/api/v1/logs/tail',
        query: {'source': selected, 'lines': '$_lines'},
      );
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      final entries = map['entries'];
      final content = entries is List
          ? entries.map(formatAuditEntry).join('\n')
          : (map['content'] as String? ?? '');
      setState(() {
        _content = content;
        _path = map['path'] as String?;
        _truncated = map['truncated'] == true;
        _error = null;
        _loadingContent = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loadingContent = false;
      });
    }
  }

  Future<void> _pickSource() async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final item in _sources)
              ListTile(
                leading: Icon(
                  item.id == _selected
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: Text(item.label),
                onTap: () => Navigator.pop(context, item.id),
              ),
          ],
        ),
      ),
    );
    if (source == null || source == _selected) return;
    setState(() => _selected = source);
    await _loadTail();
  }

  Future<void> _pickLines() async {
    final lines = await showModalBottomSheet<int>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final value in const [100, 200, 500, 1000, 2000])
              ListTile(
                leading: Icon(
                  value == _lines
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 18,
                ),
                title: Text('$value 行'),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (lines == null || lines == _lines) return;
    setState(() => _lines = lines);
    await _loadTail();
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final selectedLabel = _sources
        .where((source) => source.id == _selected)
        .map((source) => source.label)
        .firstOrNull;
    return Column(
      children: [
        PageHeader(
          title: '日志',
          actions: [
            PageRefreshButton(
              onPressed: _loadTail,
              refreshing: _loadingContent,
            ),
          ],
        ),
        if (!compact)
          Padding(
            padding: pageContentPadding(context, top: 0).copyWith(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 220,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selected,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: '日志源',
                      isDense: true,
                    ),
                    items: [
                      for (final source in _sources)
                        DropdownMenuItem(
                          value: source.id,
                          child: Text(
                            source.label,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) {
                      setState(() => _selected = value);
                      _loadTail();
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 120,
                  child: DropdownButtonFormField<int>(
                    initialValue: _lines,
                    decoration: const InputDecoration(
                      labelText: '行数',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 100, child: Text('100')),
                      DropdownMenuItem(value: 200, child: Text('200')),
                      DropdownMenuItem(value: 500, child: Text('500')),
                      DropdownMenuItem(value: 1000, child: Text('1000')),
                      DropdownMenuItem(value: 2000, child: Text('2000')),
                    ],
                    onChanged: (value) {
                      setState(() => _lines = value ?? 200);
                      _loadTail();
                    },
                  ),
                ),
              ],
            ),
          ),
        if (_error != null)
          ErrorBanner(message: _error!, onRetry: _loadSources),
        Expanded(
          child: _loading
              ? const LoadingView()
              : Padding(
                  padding: pageContentPadding(context),
                  child: LogViewer(
                    content: _content,
                    path: _path,
                    truncated: _truncated,
                  ),
                ),
        ),
        if (compact)
          ActionDock(
            actions: [
              ActionDockItem(
                icon: Icons.source_outlined,
                label: selectedLabel ?? '日志源',
                onPressed: _pickSource,
              ),
              ActionDockItem(
                icon: Icons.format_list_numbered,
                label: '$_lines 行',
                onPressed: _pickLines,
              ),
            ],
          ),
      ],
    );
  }
}
