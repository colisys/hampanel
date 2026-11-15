import 'package:material_ui/material_ui.dart';

import 'theme.dart';

enum MdBlockKind { paragraph, heading, bullet, numbered, code, quote, divider }

class MdBlock {
  const MdBlock(this.kind, {this.text = '', this.level = 0, this.items = const []});

  final MdBlockKind kind;
  final String text;
  final int level;
  final List<String> items;
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

  for (final rawLine in lines) {
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
      final hashes = trimmed.length - trimmed.replaceFirst(RegExp(r'^#+'), '').length;
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
    paragraph.add(rawLine);
  }
  if (inCode && code.isNotEmpty) {
    blocks.add(MdBlock(MdBlockKind.code, text: code.join('\n')));
  }
  flushParagraph();
  return blocks;
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
          _block(block, style),
          const SizedBox(height: 6),
        ],
      ],
    );
  }

  Widget _block(MdBlock block, TextStyle style) {
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
          style: style.copyWith(
            fontSize: size,
            fontWeight: FontWeight.w800,
          ),
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
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: hampanelSurfaceAlt,
            border: Border.all(color: hampanelBorder),
          ),
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
      case MdBlockKind.paragraph:
        return _inline(block.text, style);
    }
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
