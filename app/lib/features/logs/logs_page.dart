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
        _sources = sources;
        _selected = sources.isEmpty ? null : sources.first.id;
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

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        PageHeader(
          title: '日志',
          subtitle: '面板审计与系统日志 · 内容/级别/时间筛选',
          actions: [
            SizedBox(
              width: 180,
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
            const SizedBox(width: 8),
            SizedBox(
              width: 96,
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
            const SizedBox(width: 4),
            PageRefreshButton(
              onPressed: _loadTail,
              refreshing: _loadingContent,
            ),
          ],
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
      ],
    );
  }
}
