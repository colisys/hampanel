import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../core/format.dart';
import '../core/log_parse.dart';
import 'theme.dart';
import 'widgets.dart';

class LogViewer extends StatefulWidget {
  const LogViewer({
    super.key,
    required this.content,
    this.path,
    this.truncated = false,
    this.emptyMessage = '暂无日志内容',
  });

  final String content;
  final String? path;
  final bool truncated;
  final String emptyMessage;

  @override
  State<LogViewer> createState() => _LogViewerState();
}

class _LogViewerState extends State<LogViewer> {
  final _queryController = TextEditingController();
  List<LogLine> _lines = const [];
  final Set<LogSeverity> _severities = LogSeverity.values.toSet();
  DateTimeRange? _range;
  String _query = '';

  @override
  void initState() {
    super.initState();
    _lines = LogParser.parse(widget.content);
  }

  @override
  void didUpdateWidget(covariant LogViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.content != widget.content) {
      _lines = LogParser.parse(widget.content);
    }
  }

  @override
  void dispose() {
    _queryController.dispose();
    super.dispose();
  }

  List<LogLine> get _visible {
    final query = _query.trim().toLowerCase();
    return [
      for (final line in _lines)
        if (_matches(line, query)) line,
    ];
  }

  bool _matches(LogLine line, String query) {
    if (!_severities.contains(line.severity)) return false;
    if (query.isNotEmpty && !line.raw.toLowerCase().contains(query)) {
      return false;
    }
    final range = _range;
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
      initialDateRange: _range,
      helpText: '选择日志时间范围',
      saveText: '应用',
    );
    if (picked == null || !mounted) return;
    setState(() => _range = picked);
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

  @override
  Widget build(BuildContext context) {
    final visible = _visible;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: hampanelSurface,
            border: Border.all(color: hampanelBorder),
          ),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 240,
                child: TextField(
                  controller: _queryController,
                  onChanged: (value) => setState(() => _query = value),
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    labelText: '筛选内容',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              for (final severity in LogSeverity.values)
                FilterChip(
                  label: Text(severity.label),
                  selected: _severities.contains(severity),
                  visualDensity: VisualDensity.compact,
                  selectedColor: _severityColor(severity).withValues(alpha: 0.14),
                  onSelected: (selected) {
                    setState(() {
                      if (selected) {
                        _severities.add(severity);
                      } else {
                        _severities.remove(severity);
                      }
                    });
                  },
                ),
              OutlinedButton.icon(
                onPressed: _pickRange,
                icon: const Icon(Icons.date_range, size: 16),
                label: Text(
                  _range == null
                      ? '时间范围'
                      : '${formatTimestamp(_range!.start.toIso8601String()).substring(0, 10)}'
                            ' ~ '
                            '${formatTimestamp(_range!.end.toIso8601String()).substring(0, 10)}',
                ),
              ),
              if (_range != null)
                IconButton(
                  tooltip: '清除时间范围',
                  onPressed: () => setState(() => _range = null),
                  icon: const Icon(Icons.close, size: 16),
                ),
              Text(
                '${visible.length}/${_lines.length} 行',
                style: TextStyle(
                  fontSize: 11,
                  color: hampanelMuted,
                  fontFamily: monospace.fontFamily,
                ),
              ),
              IconButton(
                tooltip: '复制当前筛选结果',
                onPressed: visible.isEmpty ? null : _copyVisible,
                icon: const Icon(Icons.copy_all_outlined, size: 17),
              ),
              if (widget.truncated)
                Text(
                  '已截断',
                  style: TextStyle(fontSize: 10.5, color: hampanelWarning),
                ),
            ],
          ),
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
                        query: _query,
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


Future<void> showLogViewerDialog(
  BuildContext context, {
  required String title,
  required String content,
  String? path,
  bool truncated = false,
  String emptyMessage = '暂无日志',
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: DialogBody(
        maxWidth: 980,
        maxHeight: 620,
        child: LogViewer(
          content: content,
          path: path,
          truncated: truncated,
          emptyMessage: emptyMessage,
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
