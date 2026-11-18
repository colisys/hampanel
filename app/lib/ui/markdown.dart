import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'theme.dart';

enum MdBlockKind {
  paragraph,
  heading,
  bullet,
  numbered,
  code,
  quote,
  divider,
  table,
}

enum MdAlign { left, center, right }

class MdBlock {
  const MdBlock(
    this.kind, {
    this.text = '',
    this.level = 0,
    this.items = const [],
    this.header = const [],
    this.rows = const [],
    this.aligns = const [],
  });

  final MdBlockKind kind;
  final String text;
  final int level;
  final List<String> items;
  final List<String> header;
  final List<List<String>> rows;
  final List<MdAlign> aligns;
}

/// 极简 Markdown 解析：标题、列表、引用、代码块、分隔线与段落。
/// 不引入第三方依赖，只覆盖 AI 回复常见的输出形态。
List<MdBlock> parseMarkdown(String source) {
  final blocks = <MdBlock>[];
  final lines = source.replaceAll('\r\n', '\n').split('\n');
  var paragraph = <String>[];
  final code = <String>[];
  var inCode = false;

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(MdBlock(MdBlockKind.paragraph, text: paragraph.join('\n')));
    paragraph = [];
  }

  for (var lineIndex = 0; lineIndex < lines.length; lineIndex++) {
    final rawLine = lines[lineIndex];
    final trimmed = rawLine.trim();
    if (trimmed.startsWith('```')) {
      if (inCode) {
        blocks.add(MdBlock(MdBlockKind.code, text: code.join('\n')));
        code.clear();
        inCode = false;
      } else {
        flushParagraph();
        inCode = true;
      }
      continue;
    }
    if (inCode) {
      code.add(rawLine);
      continue;
    }
    if (trimmed.isEmpty) {
      flushParagraph();
      continue;
    }
    if (trimmed == '---' || trimmed == '***') {
      flushParagraph();
      blocks.add(const MdBlock(MdBlockKind.divider));
      continue;
    }
    if (trimmed.startsWith('#')) {
      final hashes =
          trimmed.length - trimmed.replaceFirst(RegExp(r'^#+'), '').length;
      if (hashes <= 6 && trimmed.length > hashes && trimmed[hashes] == ' ') {
        flushParagraph();
        blocks.add(
          MdBlock(
            MdBlockKind.heading,
            text: trimmed.substring(hashes + 1),
            level: hashes,
          ),
        );
        continue;
      }
    }
    if (trimmed.startsWith('> ')) {
      flushParagraph();
      blocks.add(MdBlock(MdBlockKind.quote, text: trimmed.substring(2)));
      continue;
    }
    if (trimmed.startsWith('- ') || trimmed.startsWith('* ')) {
      flushParagraph();
      _appendListItem(blocks, MdBlockKind.bullet, trimmed.substring(2));
      continue;
    }
    final numbered = RegExp(r'^(\d+)\.\s+(.*)$').firstMatch(trimmed);
    if (numbered != null) {
      flushParagraph();
      _appendListItem(blocks, MdBlockKind.numbered, numbered.group(2)!);
      continue;
    }
    if (trimmed.contains('|') && lineIndex + 1 < lines.length) {
      final header = _splitTableRow(trimmed);
      if (header.isNotEmpty &&
          _isTableDelimiter(lines[lineIndex + 1], header.length)) {
        final aligns = _tableAligns(lines[lineIndex + 1], header.length);
        final rows = <List<String>>[];
        var next = lineIndex + 2;
        while (next < lines.length) {
          final rowLine = lines[next].trim();
          if (rowLine.isEmpty || !rowLine.contains('|')) break;
          final cells = _splitTableRow(rowLine);
          rows.add([
            for (var c = 0; c < header.length; c++)
              c < cells.length ? cells[c] : '',
          ]);
          next += 1;
        }
        flushParagraph();
        blocks.add(
          MdBlock(
            MdBlockKind.table,
            header: header,
            rows: rows,
            aligns: aligns,
          ),
        );
        lineIndex = next - 1;
        continue;
      }
    }
    paragraph.add(rawLine);
  }
  if (inCode && code.isNotEmpty) {
    blocks.add(MdBlock(MdBlockKind.code, text: code.join('\n')));
  }
  flushParagraph();
  return blocks;
}

List<String> _splitTableRow(String line) {
  var trimmed = line.trim();
  if (trimmed.startsWith('|')) trimmed = trimmed.substring(1);
  if (trimmed.endsWith('|')) trimmed = trimmed.substring(0, trimmed.length - 1);
  return [for (final cell in trimmed.split('|')) cell.trim()];
}

bool _isTableDelimiter(String line, int columns) {
  if (!line.contains('-') || !line.contains('|')) return false;
  final cells = _splitTableRow(line);
  if (cells.length != columns) return false;
  final pattern = RegExp(r'^:?-{1,}:?$');
  return cells.every(pattern.hasMatch);
}

List<MdAlign> _tableAligns(String line, int columns) {
  final cells = _splitTableRow(line);
  return [
    for (var i = 0; i < columns; i++)
      if (i < cells.length &&
          cells[i].startsWith(':') &&
          cells[i].endsWith(':'))
        MdAlign.center
      else if (i < cells.length && cells[i].endsWith(':'))
        MdAlign.right
      else
        MdAlign.left,
  ];
}

void _appendListItem(List<MdBlock> blocks, MdBlockKind kind, String text) {
  if (blocks.isNotEmpty && blocks.last.kind == kind) {
    final last = blocks.removeLast();
    blocks.add(MdBlock(kind, items: [...last.items, text]));
  } else {
    blocks.add(MdBlock(kind, items: [text]));
  }
}

/// 渲染 Markdown 文本。行内只处理 **粗体**、*斜体* 与 `代码`。
class MarkdownText extends StatelessWidget {
  const MarkdownText(this.source, {super.key, this.baseStyle});

  final String source;
  final TextStyle? baseStyle;

  @override
  Widget build(BuildContext context) {
    final style = baseStyle ?? const TextStyle(fontSize: 12.5, height: 1.55);
    final blocks = parseMarkdown(source);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final block in blocks) ...[
          _block(context, block, style),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _block(BuildContext context, MdBlock block, TextStyle style) {
    switch (block.kind) {
      case MdBlockKind.heading:
        final size = switch (block.level) {
          1 => 18.0,
          2 => 16.0,
          3 => 14.5,
          _ => 13.0,
        };
        return Text(
          block.text,
          style: style.copyWith(fontSize: size, fontWeight: FontWeight.w800),
        );
      case MdBlockKind.bullet:
      case MdBlockKind.numbered:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < block.items.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 20,
                      child: Text(
                        block.kind == MdBlockKind.bullet ? '•' : '${i + 1}.',
                        style: style.copyWith(color: hampanelMuted),
                      ),
                    ),
                    Expanded(child: _inline(block.items[i], style)),
                  ],
                ),
              ),
          ],
        );
      case MdBlockKind.code:
        return Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: hampanelSurfaceAlt,
            border: Border.all(color: hampanelBorder),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Text(
                      '代码',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: hampanelMuted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '复制代码',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: block.text));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('代码已复制')),
                      );
                    },
                    icon: const Icon(Icons.copy_all_outlined, size: 17),
                  ),
                ],
              ),
              const Divider(height: 1),
              Padding(
                padding: const EdgeInsets.all(10),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SelectableText(
                    block.text,
                    style: TextStyle(
                      fontFamily: 'DejaVu Sans Mono',
                      fontSize: 11.5,
                      height: 1.45,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      case MdBlockKind.quote:
        return Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: hampanelAccent, width: 3)),
          ),
          child: _inline(block.text, style.copyWith(color: hampanelMuted)),
        );
      case MdBlockKind.divider:
        return Container(height: 2, color: hampanelBorder);
      case MdBlockKind.table:
        return _table(block, style);
      case MdBlockKind.paragraph:
        return _inline(block.text, style);
    }
  }

  Widget _table(MdBlock block, TextStyle style) {
    Widget cell(String text, MdAlign align, {bool header = false}) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        alignment: switch (align) {
          MdAlign.center => Alignment.center,
          MdAlign.right => Alignment.centerRight,
          MdAlign.left => Alignment.centerLeft,
        },
        child: _inline(
          text,
          header ? style.copyWith(fontWeight: FontWeight.w700) : style,
        ),
      );
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(border: Border.all(color: hampanelBorder)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Table(
          defaultColumnWidth: const IntrinsicColumnWidth(),
          border: TableBorder.symmetric(
            inside: BorderSide(color: hampanelBorder),
          ),
          children: [
            TableRow(
              decoration: BoxDecoration(color: hampanelSurfaceAlt),
              children: [
                for (var i = 0; i < block.header.length; i++)
                  cell(block.header[i], block.aligns[i], header: true),
              ],
            ),
            for (final row in block.rows)
              TableRow(
                children: [
                  for (var i = 0; i < block.header.length; i++)
                    cell(row[i], block.aligns[i]),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _inline(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    final pattern = RegExp(r'(\*\*[^*]+\*\*|\*[^*]+\*|`[^`]+`)');
    var index = 0;
    for (final match in pattern.allMatches(text)) {
      if (match.start > index) {
        spans.add(TextSpan(text: text.substring(index, match.start)));
      }
      final token = match.group(0)!;
      if (token.startsWith('**')) {
        spans.add(
          TextSpan(
            text: token.substring(2, token.length - 2),
            style: const TextStyle(fontWeight: FontWeight.w800),
          ),
        );
      } else if (token.startsWith('`')) {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: TextStyle(
              fontFamily: 'DejaVu Sans Mono',
              fontSize: style.fontSize! - 0.5,
              backgroundColor: hampanelSurfaceAlt,
            ),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: token.substring(1, token.length - 1),
            style: const TextStyle(fontStyle: FontStyle.italic),
          ),
        );
      }
      index = match.end;
    }
    if (index < text.length) {
      spans.add(TextSpan(text: text.substring(index)));
    }
    return SelectableText.rich(TextSpan(style: style, children: spans));
  }
}
