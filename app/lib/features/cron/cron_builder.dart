import 'package:material_ui/material_ui.dart';

import '../../ui/theme.dart';

class CronBuilder extends StatefulWidget {
  const CronBuilder({
    super.key,
    required this.initial,
    required this.onChanged,
  });

  final String initial;
  final ValueChanged<String> onChanged;

  @override
  State<CronBuilder> createState() => _CronBuilderState();
}

class _CronBuilderState extends State<CronBuilder> {
  late final _raw = TextEditingController(text: widget.initial);
  late bool _advanced = !_parse(widget.initial);
  late _CronField _minute;
  late _CronField _hour;
  late _CronField _day;
  late _CronField _month;
  late _CronField _weekday;

  @override
  void initState() {
    super.initState();
    final parts = widget.initial.trim().split(RegExp(r'\s+'));
    if (parts.length == 5 && !_advanced) {
      _minute = _CronField.from(parts[0]);
      _hour = _CronField.from(parts[1]);
      _day = _CronField.from(parts[2]);
      _month = _CronField.from(parts[3]);
      _weekday = _CronField.from(parts[4]);
    } else {
      _minute = _CronField(60);
      _hour = _CronField(24);
      _day = _CronField(31);
      _month = _CronField(12);
      _weekday = _CronField(7);
    }
  }

  @override
  void dispose() {
    _raw.dispose();
    super.dispose();
  }

  bool _parse(String value) {
    final parts = value.trim().split(RegExp(r'\s+'));
    if (parts.length != 5) return false;
    for (final part in parts) {
      if (part == '*') continue;
      for (final item in part.split(',')) {
        final number = int.tryParse(item);
        if (number == null) return false;
      }
    }
    return true;
  }

  void _emit() {
    final value = _advanced
        ? _raw.text.trim()
        : '${_minute.value()} ${_hour.value()} ${_day.value()} '
              '${_month.value()} ${_weekday.value()}';
    widget.onChanged(value);
  }

  void _apply(String expression) {
    _raw.text = expression;
    final parts = expression.split(RegExp(r'\s+'));
    if (parts.length != 5) return;
    setState(() {
      _advanced = false;
      _minute = _CronField.from(parts[0]);
      _hour = _CronField.from(parts[1]);
      _day = _CronField.from(parts[2]);
      _month = _CronField.from(parts[3]);
      _weekday = _CronField.from(parts[4]);
    });
    _emit();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                '执行时间',
                style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
              ),
            ),
            Text(
              _advanced ? '原始表达式' : '宫格选择',
              style: TextStyle(fontSize: 10.5, color: hampanelMuted),
            ),
            Switch(
              value: _advanced,
              onChanged: (value) {
                setState(() => _advanced = value);
                _emit();
              },
            ),
          ],
        ),
        if (_advanced)
          TextField(
            controller: _raw,
            style: monospace,
            onChanged: (_) => _emit(),
            decoration: const InputDecoration(
              labelText: 'Cron 表达式',
              hintText: '0 3 * * * 或 @daily',
              isDense: true,
            ),
          )
        else ...[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              ActionChip(
                label: const Text('每小时'),
                onPressed: () => _apply('0 * * * *'),
              ),
              ActionChip(
                label: const Text('每天 03:00'),
                onPressed: () => _apply('0 3 * * *'),
              ),
              ActionChip(
                label: const Text('每周一 03:00'),
                onPressed: () => _apply('0 3 * * 1'),
              ),
              ActionChip(
                label: const Text('每月 1 日'),
                onPressed: () => _apply('0 3 1 * *'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          _field('分钟', _minute, 60, (value) => setState(() => _minute = value)),
          _field('小时', _hour, 24, (value) => setState(() => _hour = value)),
          _field('日期', _day, 31, (value) => setState(() => _day = value)),
          _field('月份', _month, 12, (value) => setState(() => _month = value)),
          _field(
            '星期',
            _weekday,
            7,
            (value) => setState(() => _weekday = value),
            weekdayLabels: true,
          ),
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '预览：${_minute.value()} ${_hour.value()} ${_day.value()} '
              '${_month.value()} ${_weekday.value()}',
              style: monospace.copyWith(fontSize: 11, color: hampanelMuted),
            ),
          ),
        ],
      ],
    );
  }

  Widget _field(
    String label,
    _CronField field,
    int count,
    ValueChanged<_CronField> update, {
    bool weekdayLabels = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 42,
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
              Text(
                field.wildcard ? '每次' : '指定',
                style: TextStyle(fontSize: 10.5, color: hampanelMuted),
              ),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() => field.wildcard = !field.wildcard);
                  update(field);
                  _emit();
                },
                child: Text(field.wildcard ? '改为指定' : '改为每次'),
              ),
            ],
          ),
          if (!field.wildcard)
            Wrap(
              spacing: 3,
              runSpacing: 3,
              children: [
                for (var i = 0; i < count; i++)
                  FilterChip(
                    visualDensity: VisualDensity.compact,
                    label: Text(
                      weekdayLabels ? _weekdays[i] : '$i',
                      style: const TextStyle(fontSize: 10),
                    ),
                    selected: field.selected.contains(i),
                    onSelected: (selected) {
                      final next = Set<int>.from(field.selected);
                      if (selected) {
                        next.add(i);
                      } else {
                        next.remove(i);
                      }
                      setState(() {
                        field.selected = next;
                        field.wildcard = next.isEmpty;
                      });
                      update(field);
                      _emit();
                    },
                  ),
              ],
            ),
        ],
      ),
    );
  }

  static const _weekdays = ['日', '一', '二', '三', '四', '五', '六'];
}

class _CronField {
  _CronField(int count)
    : wildcard = true,
      selected = <int>{};

  _CronField.from(String value)
    : wildcard = value == '*',
      selected = value == '*'
          ? <int>{}
          : value
                .split(',')
                .map(int.tryParse)
                .whereType<int>()
                .toSet();

  bool wildcard;
  Set<int> selected;

  String value() {
    if (wildcard || selected.isEmpty) return '*';
    final values = selected.toList()..sort();
    return values.join(',');
  }
}
