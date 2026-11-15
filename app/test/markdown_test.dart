import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/ui/markdown.dart';

void main() {
  test('parses headings, lists, quotes and code fences', () {
    final blocks = parseMarkdown('''
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
'''.replaceAll('` ` `', '```'));

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
}
