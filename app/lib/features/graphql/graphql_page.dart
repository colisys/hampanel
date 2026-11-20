import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import 'graphql_client.dart';

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
        endpoint: endpoint, query: query, variables: variables, headers: headers,
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

  Widget _field(String label, ValueChanged<String> update, {int lines = 1}) => TextField(
    enabled: !busy,
    autocorrect: false,
    enableSuggestions: false,
    decoration: InputDecoration(labelText: label),
    minLines: lines,
    maxLines: lines == 1 ? 1 : null,
    onChanged: update,
  );

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    padding: const EdgeInsets.all(16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _field('HTTP(S) 端点', (v) => endpoint = v),
      _field('GraphQL 查询', (v) => query = v, lines: 3),
      _field('变量（可选 JSON 对象）', (v) => variables = v, lines: 2),
      _field('请求头（可选 JSON 对象）', (v) => headers = v, lines: 2),
      const SizedBox(height: 12),
      ElevatedButton(onPressed: busy ? null : _run, child: const Text('执行查询')),
      if (status.isNotEmpty) Text(status),
      if (body.isNotEmpty) SelectableText(body),
    ]),
  );
}
