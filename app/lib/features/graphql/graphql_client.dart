import 'dart:async';
import 'dart:convert';
import 'dart:io';

typedef GraphqlResponse = ({int status, String body});
typedef GraphqlTransport = Future<GraphqlResponse> Function(
  Uri endpoint,
  Map<String, String> headers,
  String body,
);

class GraphqlClient {
  const GraphqlClient({this.transport = _post});

  final GraphqlTransport transport;

  Future<GraphqlResponse> execute({
    required String endpoint,
    required String query,
    String variables = '',
    String headers = '',
  }) async {
    final uri = Uri.tryParse(endpoint.trim());
    if (uri == null || !{'http', 'https'}.contains(uri.scheme) || uri.host.isEmpty) {
      throw const FormatException('请输入有效的 HTTP(S) 地址');
    }
    if (query.trim().isEmpty) throw const FormatException('请输入查询');
    final fields = <String, String>{'content-type': 'application/json'};
    for (final entry in _object(headers, '请求头').entries) {
      final value = entry.value;
      if (value is! String || value.contains(RegExp(r'[\r\n]')) ||
          !RegExp(r"^[!#$%&'*+.^_`|~0-9A-Za-z-]+$").hasMatch(entry.key)) {
        throw const FormatException('请求头需要有效的名称和字符串值');
      }
      fields[entry.key.toLowerCase()] = value;
    }
    return transport(uri, fields, jsonEncode({
      'query': query,
      if (variables.trim().isNotEmpty) 'variables': _object(variables, '变量'),
    }));
  }

  static Map<String, dynamic> _object(String text, String label) {
    if (text.trim().isEmpty) return {};
    dynamic value;
    try {
      value = jsonDecode(text);
    } on FormatException {
      throw FormatException('$label 必须是 JSON 对象');
    }
    if (value is! Map<String, dynamic>) throw FormatException('$label 必须是 JSON 对象');
    return value;
  }

  static Future<GraphqlResponse> _post(Uri uri, Map<String, String> headers, String body) async {
    final client = HttpClient();
    Future<GraphqlResponse> send() async {
      final request = await client.postUrl(uri);
      request.followRedirects = false;
      headers.forEach((key, value) => request.headers.set(key, value));
      request.add(utf8.encode(body));
      final response = await request.close();
      return (status: response.statusCode, body: await response.transform(utf8.decoder).join());
    }
    try {
      return await send().timeout(const Duration(seconds: 30));
    } finally {
      client.close(force: true);
    }
  }
}
