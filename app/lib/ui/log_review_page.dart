import 'package:material_ui/material_ui.dart';

import 'code_editor.dart';
import 'theme.dart';

/// Shows the exact log content an AI tool is about to read. The user can edit
/// or delete lines before the result is handed to the assistant.
class LogReviewPage extends StatefulWidget {
  const LogReviewPage({super.key, required this.title, required this.content});

  final String title;
  final String content;

  @override
  State<LogReviewPage> createState() => _LogReviewPageState();
}

class _LogReviewPageState extends State<LogReviewPage> {
  final _editorKey = GlobalKey<CodeEditorPaneState>();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('日志人工预检'),
            Text(
              widget.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10.5, color: hampanelMuted),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 6),
          FilledButton.icon(
            onPressed: () =>
                Navigator.of(context).pop(_editorKey.currentState?.text ?? ''),
            icon: const Icon(Icons.send_outlined, size: 16),
            label: const Text('发送给助手'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: hampanelSurfaceAlt,
            child: Text(
              '下面是将要发送给助手的原始日志。可以直接修改或删除敏感行；'
              '助手只会收到这里最终的内容。',
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
              child: CodeEditorPane(
                key: _editorKey,
                initialText: widget.content,
                language: CodeLanguage.plain,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
