import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'ai_context.dart';
import 'enrollment.dart';

class ApiException implements Exception {
  const ApiException(this.status, this.code, this.message);

  final int status;
  final String code;
  final String message;

  @override
  String toString() => message.isEmpty ? 'HTTP $status' : message;
}

class ApiClient {
  ApiClient(this.enrollment) {
    final context = SecurityContext(withTrustedRoots: false);
    context.setTrustedCertificatesBytes(utf8.encode(enrollment.caPem));
    context.useCertificateChainBytes(utf8.encode(enrollment.clientCertPem));
    context.usePrivateKeyBytes(utf8.encode(enrollment.clientKeyPem));

    _http = HttpClient(context: context)
      ..connectionTimeout = const Duration(seconds: 12)
      ..idleTimeout = const Duration(seconds: 30)
      ..userAgent = 'Hampanel-Flutter/0.1';
  }

  final Enrollment enrollment;
  late final HttpClient _http;

  ({String host, int port}) get _target {
    final raw = enrollment.endpoint.trim();
    if (raw.startsWith('[')) {
      final close = raw.indexOf(']');
      if (close < 0) throw const FormatException('endpoint 格式错误');
      final host = raw.substring(1, close);
      final rest = raw.substring(close + 1);
      return (
        host: host,
        port: rest.startsWith(':') ? int.parse(rest.substring(1)) : 8443,
      );
    }
    final colon = raw.lastIndexOf(':');
    if (colon <= 0) return (host: raw, port: 8443);
    return (
      host: raw.substring(0, colon),
      port: int.parse(raw.substring(colon + 1)),
    );
  }

  String get _entryPrefix {
    final raw = enrollment.entryPrefix.trim();
    if (raw.isEmpty) return '';
    return raw.startsWith('/') ? raw : '/$raw';
  }

  Uri uri(String path, [Map<String, String>? query, String scheme = 'https']) {
    final target = _target;
    return Uri(
      scheme: scheme,
      host: target.host,
      port: target.port,
      path: '$_entryPrefix$path',
      queryParameters: (query == null || query.isEmpty) ? null : query,
    );
  }

  Future<dynamic> getJson(String path, {Map<String, String>? query}) =>
      _send('GET', path, query: query);

  Future<dynamic> postJson(
    String path,
    Object? body, {
    Map<String, String>? query,
    Duration? timeout,
  }) => _send(
    'POST',
    path,
    body: body,
    query: query,
    timeout: timeout ?? const Duration(seconds: 30),
  );

  Future<dynamic> putJson(
    String path,
    Object? body, {
    Map<String, String>? query,
  }) => _send('PUT', path, body: body, query: query);

  Future<dynamic> deleteJson(String path, {Map<String, String>? query}) =>
      _send('DELETE', path, query: query);

  Future<dynamic> _send(
    String method,
    String path, {
    Object? body,
    Map<String, String>? query,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    try {
      final request = await _http.openUrl(method, uri(path, query));
      if (AiRequestContext.active) {
        request.headers.set('x-hampanel-ai', '1');
      }
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(timeout);
      final bytes = await response.fold<List<int>>(
        <int>[],
        (buffer, chunk) => buffer..addAll(chunk),
      );
      final text = utf8.decode(bytes, allowMalformed: true);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        if (text.trim().isEmpty) return null;
        try {
          return jsonDecode(text);
        } on FormatException {
          return text;
        }
      }
      throw _errorFrom(response.statusCode, text);
    } on SocketException catch (error) {
      throw ApiException(
        0,
        'network',
        '无法连接 ${enrollment.endpoint}: ${error.message}',
      );
    } on HandshakeException catch (error) {
      throw ApiException(0, 'tls', 'TLS 握手失败: ${error.message}');
    } on TimeoutException {
      throw const ApiException(0, 'timeout', '请求超时');
    }
  }

  Future<File> downloadToFile(
    String path,
    Map<String, String> query,
    String localPath,
  ) async {
    final request = await _http.getUrl(uri(path, query));
    final response = await request.close();
    final file = File(localPath);
    await file.parent.create(recursive: true);
    if (response.statusCode != 200) {
      final text = await utf8.decodeStream(response);
      throw _errorFrom(response.statusCode, text);
    }
    final sink = file.openWrite();
    await response.pipe(sink);
    return file;
  }

  Future<dynamic> uploadFromFile(
    String path,
    Map<String, String> query,
    String localPath,
  ) async {
    final file = File(localPath);
    if (!await file.exists()) {
      throw ApiException(0, 'missing_file', '本地文件不存在: $localPath');
    }
    final length = await file.length();
    final request = await _http.postUrl(uri(path, query));
    request.headers.contentType = ContentType.binary;
    request.contentLength = length;
    await request.addStream(file.openRead());
    final response = await request.close();
    final text = await utf8.decodeStream(response);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw _errorFrom(response.statusCode, text);
    }
    return text.trim().isEmpty ? null : jsonDecode(text);
  }

  Future<WebSocket> openTerminal({required int cols, required int rows}) {
    final url = uri('/api/v1/terminal/ws', {
      'cols': '$cols',
      'rows': '$rows',
    }, 'wss');
    return WebSocket.connect(url.toString(), customClient: _http);
  }

  ApiException _errorFrom(int status, String text) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) {
        return ApiException(
          status,
          decoded['code'] as String? ?? 'error',
          decoded['message'] as String? ?? text,
        );
      }
    } on FormatException {
      // fall through
    }
    return ApiException(
      status,
      'error',
      text.trim().isEmpty ? 'HTTP $status' : text.trim(),
    );
  }

  void close() {
    _http.close(force: true);
  }
}

String describeError(Object error) {
  if (error is ApiException) {
    if (error.code == 'unsupported') return '当前平台不支持此功能';
    return error.message;
  }
  return error.toString();
}
