import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/format.dart';
import '../../core/models/log_source.dart';
import '../../core/log_parse.dart';
import '../../core/session.dart';
import '../../ui/layout.dart';
import '../../ui/log_viewer.dart';
import '../../ui/theme.dart';
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
  final _filter = LogFilterController();

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

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

  Future<void> _openAdvancedFilters() async {
    final result = await showDialog<_LogFilters>(
      context: context,
      builder: (_) => _LogFiltersDialog(
        severities: _filter.severities,
        range: _filter.range,
        lines: _lines,
      ),
    );
    if (result == null || !mounted) return;
    _filter.setSeverities(result.severities);
    _filter.setRange(result.range);
    if (result.lines != _lines) {
      setState(() => _lines = result.lines);
      await _loadTail();
    }
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 720;
    final selectedLabel = _sources
        .where((source) => source.id == _selected)
        .map((source) => source.label)
        .firstOrNull;
    final mobileSourceLabel = (selectedLabel ?? '日志源').runes
        .take(5)
        .map(String.fromCharCode)
        .join();
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
                    controller: _filter,
                    compactFilters: true,
                    onAdvancedFilter: _openAdvancedFilters,
                  ),
                ),
        ),
        if (compact)
          ActionDock(
            actions: [
              ActionDockItem(
                icon: Icons.source_outlined,
                label: mobileSourceLabel,
                onPressed: _pickSource,
              ),
            ],
          ),
      ],
    );
  }
}

class _LogFilters {
  const _LogFilters(this.severities, this.range, this.lines);

  final Set<LogSeverity> severities;
  final DateTimeRange? range;
  final int lines;
}

class _LogFiltersDialog extends StatefulWidget {
  const _LogFiltersDialog({
    required this.severities,
    required this.range,
    required this.lines,
  });

  final Set<LogSeverity> severities;
  final DateTimeRange? range;
  final int lines;

  @override
  State<_LogFiltersDialog> createState() => _LogFiltersDialogState();
}

class _LogFiltersDialogState extends State<_LogFiltersDialog> {
  late Set<LogSeverity> _severities = {...widget.severities};
  late DateTimeRange? _range = widget.range;
  late int _lines = widget.lines;

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _range,
      helpText: '选择日志时间范围',
      saveText: '应用',
      locale: const Locale('zh', 'CN'),
    );
    if (picked != null && mounted) setState(() => _range = picked);
  }

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('高级筛选'),
      content: DialogBody(
        maxWidth: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '日志类型',
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final severity in LogSeverity.values)
                  FilterChip(
                    label: Text(severity.label),
                    selected: _severities.contains(severity),
                    showCheckmark: false,
                    onSelected: (selected) => setState(() {
                      if (selected) {
                        _severities.add(severity);
                      } else {
                        _severities.remove(severity);
                      }
                    }),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '时间范围',
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _pickRange,
                    icon: const Icon(Icons.date_range, size: 16),
                    label: Text(
                      _range == null
                          ? '不限时间'
                          : '${_date(_range!.start)} ~ ${_date(_range!.end)}',
                    ),
                  ),
                ),
                if (_range != null)
                  IconButton(
                    tooltip: '清除时间范围',
                    onPressed: () => setState(() => _range = null),
                    icon: const Icon(Icons.close, size: 16),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<int>(
              key: ValueKey(_lines),
              initialValue: _lines,
              decoration: const InputDecoration(
                labelText: '读取行数',
                isDense: true,
              ),
              items: [
                for (final count in const [100, 200, 500, 1000, 2000])
                  DropdownMenuItem(value: count, child: Text('$count 行')),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _lines = value);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => setState(() {
            _severities = LogSeverity.values.toSet();
            _range = null;
            _lines = 200;
          }),
          child: const Text('重置'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            _LogFilters({..._severities}, _range, _lines),
          ),
          child: const Text('应用'),
        ),
      ],
    );
  }
}
