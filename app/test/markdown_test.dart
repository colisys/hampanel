import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/ui/markdown.dart';

void main() {
  test('parses headings, lists, quotes and code fences', () {
    final blocks = parseMarkdown(
      '''
# 标题
第一段
- 项目一
- 项目二

1. 步骤一
2. 步骤二

> 引用

` ` `
code line
` ` `
'''
          .replaceAll('` ` `', '```'),
    );

    expect(blocks.map((block) => block.kind).toList(), [
      MdBlockKind.heading,
      MdBlockKind.paragraph,
      MdBlockKind.bullet,
      MdBlockKind.numbered,
      MdBlockKind.quote,
      MdBlockKind.code,
    ]);
    expect(blocks[0].text, '标题');
    expect(blocks[0].level, 1);
    expect(blocks[2].items, ['项目一', '项目二']);
    expect(blocks[3].items, ['步骤一', '步骤二']);
    expect(blocks[4].text, '引用');
    expect(blocks[5].text, 'code line');
  });

  test('parses tables with alignment and padding', () {
    final blocks = parseMarkdown('''
| 名称 | 状态 | 端口 |
|:-----|:----:|-----:|
| nginx | 运行中 | 80 |
| 未完成的 | 行 | 
''');

    expect(blocks.length, 1);
    final table = blocks.single;
    expect(table.kind, MdBlockKind.table);
    expect(table.header, ['名称', '状态', '端口']);
    expect(table.aligns, [MdAlign.left, MdAlign.center, MdAlign.right]);
    expect(table.rows.length, 2);
    expect(table.rows[0], ['nginx', '运行中', '80']);
    expect(table.rows[1], ['未完成的', '行', '']);
  });

  test('keeps pipe paragraphs when there is no delimiter row', () {
    final blocks = parseMarkdown('a | b\nc | d');
    expect(blocks.single.kind, MdBlockKind.paragraph);
    expect(blocks.single.text, 'a | b\nc | d');
  });
}
