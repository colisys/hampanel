import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/log_parse.dart';
import 'theme.dart';

/// Shared filter state so a page can put severity, date and query controls in
/// its own advanced-filter dialog while [LogViewer] renders the result.
class LogFilterController extends ChangeNotifier {
  String query = '';
  Set<LogSeverity> severities = LogSeverity.values.toSet();
  DateTimeRange? range;

  bool get isDefault =>
      query.trim().isEmpty &&
      severities.length == LogSeverity.values.length &&
      range == null;

  int get activeCount =>
      (query.trim().isEmpty ? 0 : 1) +
      (severities.length == LogSeverity.values.length ? 0 : 1) +
      (range == null ? 0 : 1);

  void setQuery(String value) {
    if (query == value) return;
    query = value;
    notifyListeners();
  }

  void setSeverities(Set<LogSeverity> value) {
    severities = {...value};
    notifyListeners();
  }

  void setRange(DateTimeRange? value) {
    range = value;
    notifyListeners();
  }

  void reset() {
    query = '';
    severities = LogSeverity.values.toSet();
    range = null;
    notifyListeners();
  }
}

class LogViewer extends StatefulWidget {
  const LogViewer({
    super.key,
    required this.content,
    this.path,
    this.truncated = false,
    this.emptyMessage = '暂无日志内容',
    this.controller,
    this.compactFilters = false,
    this.onAdvancedFilter,
    this.onCountChanged,
  });

  final String content;
  final String? path;
  final bool truncated;
  final String emptyMessage;

  /// Optional shared filter state. When omitted the viewer owns one.
  final LogFilterController? controller;

  /// Hides the severity/date controls behind [onAdvancedFilter] and leaves only
  /// the search field in the inline bar.
  final bool compactFilters;
  final VoidCallback? onAdvancedFilter;

  /// Reports the filtered and total line counts after a rebuild.
  final void Function(int visible, int total)? onCountChanged;

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  final _queryController = TextEditingController();
  List<LogLine> _lines = const [];
  late final LogFilterController _filter =
      widget.controller ?? LogFilterController();
  int _lastVisible = -1;
  int _lastTotal = -1;

  LogFilterController get _activeFilter => widget.controller ?? _filter;

  @override
  void initState() {
    super.initState();
    _lines = LogParser.parse(widget.content);
    _queryController.text = _activeFilter.query;
    _activeFilter.addListener(_onFilterChanged);
  }

  void _onFilterChanged() {
    if (!mounted) return;
    if (_queryController.text != _activeFilter.query) {
      _queryController.text = _activeFilter.query;
    }
    setState(() {});
  }

  @override
  void didUpdateWidget(covariant LogViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _lines = LogParser.parse(widget.content);
    }
    if (oldWidget.controller != widget.controller) {
      (oldWidget.controller ?? _filter).removeListener(_onFilterChanged);
      (widget.controller ?? _filter).addListener(_onFilterChanged);
    }
  }

  @override
  void dispose() {
    _activeFilter.removeListener(_onFilterChanged);
    if (widget.controller == null) _filter.dispose();
    _queryController.dispose();
    super.dispose();
  }

  List<LogLine> get _visible {
    final query = _activeFilter.query.trim().toLowerCase();
    return [
      for (final line in _lines)
        if (_matches(line, query)) line,
    ];
  }

  bool _matches(LogLine line, String query) {
    if (!_activeFilter.severities.contains(line.severity)) return false;
    if (query.isNotEmpty && !line.raw.toLowerCase().contains(query)) {
      return false;
    }
    final range = _activeFilter.range;
    if (range != null) {
      final timestamp = line.timestamp;
      if (timestamp == null) return false;
      final start = DateTime(
        range.start.year,
        range.start.month,
        range.start.day,
      );
      final end = DateTime(
        range.end.year,
        range.end.month,
        range.end.day,
      ).add(const Duration(days: 1));
      if (timestamp.isBefore(start) || !timestamp.isBefore(end)) return false;
    }
    return true;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(now.year - 3),
      lastDate: DateTime(now.year + 1, 12, 31),
      initialDateRange: _activeFilter.range,
      helpText: '选择日志时间范围',
      saveText: '应用',
      locale: const Locale('zh', 'CN'),
    );
    if (picked == null || !mounted) return;
    _activeFilter.setRange(picked);
  }

  void _copyVisible() {
    final text = _visible.map((line) => line.raw).join('\n');
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已复制 ${_visible.length} 行日志')),
    );
  }

  Color _severityColor(LogSeverity severity) {
    switch (severity) {
      case LogSeverity.error:
        return hampanelDanger;
      case LogSeverity.warning:
        return hampanelWarning;
      case LogSeverity.debug:
        return hampanelMuted;
      case LogSeverity.info:
        return hampanelInkSoft;
    }
  }

  Widget _severityChip(LogSeverity severity) {
    final selected = _activeFilter.severities.contains(severity);
    final color = _severityColor(severity);
    return FilterChip(
      label: Text(severity.label),
      selected: selected,
      showCheckmark: false,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
      visualDensity: const VisualDensity(horizontal: -1, vertical: -1),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      labelStyle: TextStyle(
        fontSize: 11.5,
        color: selected ? hampanelInk : hampanelMuted,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
      ),
      backgroundColor: hampanelSurface,
      selectedColor: color.withValues(alpha: 0.14),
      side: BorderSide(
        color: selected ? color : hampanelBorder,
      ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
      onSelected: (value) {
        final next = {..._activeFilter.severities};
        if (value) {
          next.add(severity);
        } else {
          next.remove(severity);
        }
        _activeFilter.setSeverities(next);
      },
    );
  }

  Widget _searchField(double height) {
    return SizedBox(
      height: height,
      child: TextField(
        controller: _queryController,
        onChanged: _activeFilter.setQuery,
        style: const TextStyle(fontSize: 12),
        textAlignVertical: TextAlignVertical.center,
        decoration: const InputDecoration(
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          prefixIcon: Icon(Icons.search, size: 18),
          labelText: '筛选内容',
          border: OutlineInputBorder(),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    if (visible.length != _lastVisible || _lines.length != _lastTotal) {
      _lastVisible = visible.length;
      _lastTotal = _lines.length;
      final report = widget.onCountChanged;
      if (report != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) report(visible.length, _lines.length);
        });
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LayoutBuilder(
          builder: (context, constraints) {
            final textHeight = MediaQuery.textScalerOf(context).scale(14);
            final height = 48.0 + (textHeight > 14 ? textHeight - 14 : 0);
            final inlineWidth = 360 * (textHeight > 14 ? textHeight / 14 : 1);
            final copy = IconButton(
              tooltip: '复制当前筛选结果',
              onPressed: visible.isEmpty ? null : _copyVisible,
              icon: const Icon(Icons.copy_all_outlined, size: 17),
            );
            final truncated = Text(
              '已截断',
              style: TextStyle(fontSize: 10.5, color: hampanelWarning),
            );
            if (widget.compactFilters) {
              final advanced = SizedBox(
                height: height,
                child: OutlinedButton.icon(
                  style: const ButtonStyle(
                    visualDensity: VisualDensity.standard,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: widget.onAdvancedFilter,
                  icon: const Icon(Icons.tune, size: 16),
                  label: Text(
                    _activeFilter.activeCount == 0
                        ? '高级筛选'
                        : '高级筛选 · ${_activeFilter.activeCount}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              );
              if (constraints.maxWidth >= inlineWidth) {
                return Row(
                  children: [
                    Expanded(child: _searchField(height)),
                    const SizedBox(width: 8),
                    advanced,
                    copy,
                    if (widget.truncated) truncated,
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _searchField(height),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [advanced, copy, if (widget.truncated) truncated],
                  ),
                ],
              );
            }
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                SizedBox(width: 240, child: _searchField(height)),
                for (final severity in LogSeverity.values)
                  _severityChip(severity),
                OutlinedButton.icon(
                  onPressed: _pickRange,
                  icon: const Icon(Icons.date_range, size: 16),
                  label: Text(
                    _activeFilter.range == null
                        ? '时间范围'
                        : '${formatTimestamp(_activeFilter.range!.start.toIso8601String()).substring(0, 10)}'
                              ' ~ '
                              '${formatTimestamp(_activeFilter.range!.end.toIso8601String()).substring(0, 10)}',
                  ),
                ),
                if (_activeFilter.range != null)
                  IconButton(
                    tooltip: '清除时间范围',
                    onPressed: () => _activeFilter.setRange(null),
                    icon: const Icon(Icons.close, size: 16),
                  ),
                copy,
                if (widget.truncated) truncated,
              ],
            );
          },
        ),
        if (widget.path != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 6, 2, 0),
            child: Text(
              widget.path!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monospace.copyWith(
                fontSize: 10.5,
                color: hampanelMuted,
              ),
            ),
          ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: hampanelSurface,
              border: Border.all(color: hampanelBorder),
            ),
            child: visible.isEmpty
                ? Center(
                    child: Text(
                      _lines.isEmpty ? widget.emptyMessage : '没有匹配的日志行',
                      style: TextStyle(fontSize: 12, color: hampanelMuted),
                    ),
                  )
                : Scrollbar(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: visible.length,
                      itemBuilder: (context, index) => _LogLineRow(
                        line: visible[index],
                        number: visible[index].number,
                        query: _activeFilter.query,
                        color: _severityColor(visible[index].severity),
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }
}

class _LogLineRow extends StatelessWidget {
  const _LogLineRow({
    required this.line,
    required this.number,
    required this.query,
    required this.color,
  });

  final LogLine line;
  final int number;
  final String query;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final timestamp = line.timestamp == null
        ? ''
        : formatTimestamp(line.timestamp!.toIso8601String());
    final base = monospace.copyWith(fontSize: 11.5, color: hampanelInk);
    final muted = base.copyWith(color: hampanelMuted);
    return Container(
      color: line.severity == LogSeverity.error
          ? hampanelDanger.withValues(alpha: 0.05)
          : line.severity == LogSeverity.warning
          ? hampanelWarning.withValues(alpha: 0.06)
          : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: SelectableText.rich(
        TextSpan(
          children: [
            TextSpan(
              text: '${number.toString().padLeft(4)} ',
              style: muted,
            ),
            if (timestamp.isNotEmpty)
              TextSpan(
                text: '$timestamp ',
                style: muted,
              ),
            TextSpan(
              text: '${_severityMark(line.severity)} ',
              style: base.copyWith(color: color, fontWeight: FontWeight.w700),
            ),
            ..._highlight(line.raw, query, base),
          ],
        ),
      ),
    );
  }

  String _severityMark(LogSeverity severity) {
    switch (severity) {
      case LogSeverity.error:
        return 'E';
      case LogSeverity.warning:
        return 'W';
      case LogSeverity.debug:
        return 'D';
      case LogSeverity.info:
        return 'I';
    }
  }

  List<TextSpan> _highlight(String text, String query, TextStyle base) {
    final needle = query.trim();
    if (needle.isEmpty) return [TextSpan(text: text, style: base)];
    final lower = text.toLowerCase();
    final target = needle.toLowerCase();
    final spans = <TextSpan>[];
    var index = 0;
    while (true) {
      final match = lower.indexOf(target, index);
      if (match < 0) {
        spans.add(TextSpan(text: text.substring(index), style: base));
        return spans;
      }
      if (match > index) {
        spans.add(TextSpan(text: text.substring(index, match), style: base));
      }
      spans.add(
        TextSpan(
          text: text.substring(match, match + target.length),
          style: base.copyWith(
            backgroundColor: hampanelWarning.withValues(alpha: 0.25),
            fontWeight: FontWeight.w700,
          ),
        ),
      );
      index = match + target.length;
      if (index >= text.length) return spans;
    }
  }
}
