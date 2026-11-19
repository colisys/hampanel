import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/api_client.dart';
import '../core/log_parse.dart';
import '../ui/layout.dart';
import '../ui/log_viewer.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';

/// Content loaded for a [LogPage].
class LogPageData {
  const LogPageData({
    required this.content,
    this.path,
    this.truncated = false,
    this.emptyMessage = '暂无日志',
  });

  final String content;
  final String? path;
  final bool truncated;
  final String emptyMessage;
}

/// Shared log screen: one title, refresh only, a search field, an advanced
/// filter dialog and the match count under the list.
///
/// Pass either [load] for a line-count based fetch or [stream] for a live
/// source such as a task's SSE output.
class LogPage extends StatefulWidget {
  const LogPage({
    super.key,
    required this.title,
    this.load,
    this.stream,
    this.initialLines = 1000,
    this.allowLineCount = true,
    this.emptyMessage = '暂无日志',
  });

  final String title;

  /// Static source. Receives the requested line count.
  final Future<LogPageData> Function(int lines)? load;

  /// Live source. Chunks are appended as they arrive.
  final Stream<String> Function()? stream;

  final int initialLines;
  final bool allowLineCount;
  final String emptyMessage;

  @override
  State<LogPage> createState() => _LogPageState();
}

class _LogPageState extends State<LogPage> {
  final _filter = LogFilterController();
  final _content = StringBuffer();
  StreamSubscription<String>? _subscription;
  late int _lines = widget.initialLines;
  String? _path;
  bool _truncated = false;
  bool _loading = true;
  String? _error;
  int _visible = 0;
  int _total = 0;

  bool get _live => widget.stream != null;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _filter.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final loader = widget.load;
    if (loader != null) {
      setState(() {
        _loading = true;
        _error = null;
      });
      try {
        final data = await loader(_lines);
        if (!mounted) return;
        setState(() {
          _content
            ..clear()
            ..write(data.content);
          _path = data.path;
          _truncated = data.truncated;
          _loading = false;
        });
      } catch (error) {
        if (!mounted) return;
        setState(() {
          _error = describeError(error);
          _loading = false;
        });
      }
      return;
    }
    await _subscription?.cancel();
    _subscription = null;
    if (!mounted) return;
    setState(() {
      _content.clear();
      _loading = true;
      _error = null;
      _truncated = false;
    });
    final stream = widget.stream;
    if (stream == null) {
      setState(() => _loading = false);
      return;
    }
    _subscription = stream().listen(
      (chunk) {
        if (!mounted) return;
        setState(() {
          _content.write(chunk);
          _loading = false;
        });
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _error = describeError(error);
          _loading = false;
        });
      },
      onDone: () {
        if (mounted) setState(() => _loading = false);
      },
    );
    setState(() => _loading = false);
  }

  Future<void> _openAdvancedFilters() async {
    final result = await showDialog<_AdvancedFilterResult>(
      context: context,
      builder: (_) => _AdvancedFilterDialog(
        severities: {..._filter.severities},
        range: _filter.range,
        lines: _lines,
        allowLineCount: widget.allowLineCount && !_live,
      ),
    );
    if (result == null || !mounted) return;
    _filter.setSeverities(result.severities);
    _filter.setRange(result.range);
    if (result.lines != _lines) {
      _lines = result.lines;
      await _reload();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          PageRefreshButton(onPressed: _reload, refreshing: _loading),
          const SizedBox(width: 8),
        ],
      ),
      body: Padding(
        padding: pageContentPadding(context),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              ErrorBanner(message: _error!, onRetry: _reload),
              const SizedBox(height: 10),
            ],
            Expanded(
              child: _loading && _content.isEmpty
                  ? const LoadingView()
                  : LogViewer(
                      content: _content.toString(),
                      path: _path,
                      truncated: _truncated,
                      emptyMessage: widget.emptyMessage,
                      controller: _filter,
                      compactFilters: true,
                      onAdvancedFilter: _openAdvancedFilters,
                      onCountChanged: (visible, total) {
                        if (visible == _visible && total == _total) return;
                        setState(() {
                          _visible = visible;
                          _total = total;
                        });
                      },
                    ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(top: 4, right: 2),
                child: Text(
                  '显示 $_visible / $_total 行',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: hampanelMuted,
                    fontFamily: monospace.fontFamily,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _AdvancedFilterResult {
  const _AdvancedFilterResult({
    required this.severities,
    required this.range,
    required this.lines,
  });

  final Set<LogSeverity> severities;
  final DateTimeRange? range;
  final int lines;
}

class _AdvancedFilterDialog extends StatefulWidget {
  const _AdvancedFilterDialog({
    required this.severities,
    required this.range,
    required this.lines,
    required this.allowLineCount,
  });

  final Set<LogSeverity> severities;
  final DateTimeRange? range;
  final int lines;
  final bool allowLineCount;

  @override
  State<_AdvancedFilterDialog> createState() => _AdvancedFilterDialogState();
}

class _AdvancedFilterDialogState extends State<_AdvancedFilterDialog> {
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
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
  }

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
              '日志级别',
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
                    visualDensity: const VisualDensity(
                      horizontal: -1,
                      vertical: -1,
                    ),
                    onSelected: (value) {
                      setState(() {
                        if (value) {
                          _severities.add(severity);
                        } else {
                          _severities.remove(severity);
                        }
                      });
                    },
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text('时间范围', style: TextStyle(fontSize: 11.5, color: hampanelMuted)),
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
            if (widget.allowLineCount) ...[
              const SizedBox(height: 16),
              DropdownButtonFormField<int>(
                initialValue: _lines,
                decoration: const InputDecoration(
                  labelText: '读取行数',
                  isDense: true,
                ),
                items: const [
                  DropdownMenuItem(value: 300, child: Text('最近 300 行')),
                  DropdownMenuItem(value: 1000, child: Text('最近 1000 行')),
                  DropdownMenuItem(value: 2000, child: Text('最近 2000 行')),
                ],
                onChanged: (value) {
                  if (value != null) setState(() => _lines = value);
                },
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () {
            setState(() {
              _severities = LogSeverity.values.toSet();
              _range = null;
            });
          },
          child: const Text('重置'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            _AdvancedFilterResult(
              severities: _severities,
              range: _range,
              lines: _lines,
            ),
          ),
          child: const Text('应用'),
        ),
      ],
    );
  }

  String _date(DateTime value) =>
      '${value.year}-${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';
}
