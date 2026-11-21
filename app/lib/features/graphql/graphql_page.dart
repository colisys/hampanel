import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../../ui/code_editor.dart';
import '../../ui/layout.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';
import 'graphql_client.dart';

/// A small GraphQL console: request on the left, response below.
///
/// The previous layout stacked four unspaced text fields, a button and the raw
/// response in one column, which read as a wall of controls. Each part now has
/// its own card with room to breathe, and the editors get real height.
class GraphqlPage extends StatefulWidget {
  const GraphqlPage({super.key, this.client = const GraphqlClient()});

  final GraphqlClient client;

  @override
  State<GraphqlPage> createState() => _GraphqlPageState();
}

class _GraphqlPageState extends State<GraphqlPage> {
  String endpoint = '', query = '', variables = '', headers = '';
  String status = '', body = '';
  bool busy = false;

  Future<void> _run() async {
    if (busy) return;
    setState(() {
      busy = true;
      status = '正在请求…';
      body = '';
    });
    try {
      final response = await widget.client.execute(
        endpoint: endpoint,
        query: query,
        variables: variables,
        headers: headers,
      );
      if (!mounted) return;
      status = 'HTTP ${response.status}';
      body = response.body;
      try {
        body = const JsonEncoder.withIndent('  ').convert(jsonDecode(body));
      } on FormatException {
        status += ' · 非 JSON 响应';
      }
    } on FormatException catch (error) {
      if (mounted) status = error.message;
    } catch (_) {
      if (mounted) status = '请求失败，请检查地址和网络连接';
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final requestCard = PanelCard(
      title: '请求',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            enabled: !busy,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'HTTP(S) 端点',
              hintText: 'https://example.com/graphql',
            ),
            onChanged: (value) => endpoint = value,
          ),
          const SizedBox(height: 14),
          _EditorBlock(
            label: 'GraphQL 查询',
            initial: query,
            language: CodeLanguage.plain,
            onChanged: (value) => query = value,
          ),
          const SizedBox(height: 14),
          _EditorBlock(
            label: '变量（可选 JSON 对象）',
            initial: variables,
            language: CodeLanguage.json,
            onChanged: (value) => variables = value,
          ),
          const SizedBox(height: 14),
          _EditorBlock(
            label: '请求头（可选 JSON 对象）',
            initial: headers,
            language: CodeLanguage.json,
            onChanged: (value) => headers = value,
          ),
          const SizedBox(height: 16),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: FilledButton.icon(
              onPressed: busy ? null : _run,
              icon: busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.play_arrow, size: 18),
              label: const Text('执行查询'),
            ),
          ),
        ],
      ),
    );

    final responseCard = PanelCard(
      title: '响应',
      trailing: status.isEmpty
          ? null
          : Text(
              status,
              style: TextStyle(fontSize: 11.5, color: hampanelMuted),
            ),
      child: body.isEmpty
          ? Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                busy ? '正在等待响应…' : '执行查询后在此显示结果。',
                style: TextStyle(fontSize: 12, color: hampanelMuted),
              ),
            )
          : SelectableText(
              body,
              style: monospace.copyWith(fontSize: 12, height: 1.5),
            ),
    );

    return SingleChildScrollView(
      padding: pageContentPadding(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [requestCard, const SizedBox(height: 16), responseCard],
      ),
    );
  }
}

/// A labelled editor with a fixed height, so four of them do not collapse into
/// a few cramped rows.
class _EditorBlock extends StatelessWidget {
  const _EditorBlock({
    required this.label,
    required this.initial,
    required this.language,
    required this.onChanged,
  });

  final String label;
  final String initial;
  final CodeLanguage language;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            label,
            style: TextStyle(fontSize: 11.5, color: hampanelMuted),
          ),
        ),
        SizedBox(
          height: 160,
          child: DecoratedBox(
            decoration: BoxDecoration(
              border: Border.all(color: hampanelBorder),
            ),
            child: CodeEditorPane(
              initialText: initial,
              language: language,
              wordWrap: true,
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }
}
