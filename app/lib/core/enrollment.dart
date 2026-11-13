import 'dart:convert';
import 'dart:io';

class Enrollment {
  const Enrollment({
    required this.schema,
    required this.endpoint,
    required this.entryPrefix,
    required this.caPem,
    required this.clientCertPem,
    required this.clientKeyPem,
    required this.caSha256,
    required this.serverSha256,
    required this.clientCn,
    required this.createdAt,
  });

  final int schema;
  final String endpoint;
  final String entryPrefix;
  final String caPem;
  final String clientCertPem;
  final String clientKeyPem;
  final String caSha256;
  final String serverSha256;
  final String clientCn;
  final String createdAt;

  factory Enrollment.fromJson(Map<String, dynamic> json) {
    String required(String key) {
      final value = json[key];
      if (value is! String || value.trim().isEmpty) {
        throw FormatException('注册凭据缺少字段: $key');
      }
      return value;
    }

    final endpoint = required('endpoint');
    if (!endpoint.contains(':')) {
      throw const FormatException('endpoint 必须为 host:port');
    }

    return Enrollment(
      schema: (json['schema'] as num?)?.toInt() ?? 1,
      endpoint: endpoint,
      entryPrefix: json['entry_prefix'] as String? ?? '',
      caPem: required('ca_pem'),
      clientCertPem: required('client_cert_pem'),
      clientKeyPem: required('client_key_pem'),
      caSha256: json['ca_sha256'] as String? ?? '',
      serverSha256: json['server_sha256'] as String? ?? '',
      clientCn: json['client_cn'] as String? ?? '',
      createdAt: json['created_at'] as String? ?? '',
    );
  }

  factory Enrollment.fromText(String text) {
    final decoded = jsonDecode(text.trim());
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('注册凭据必须是 JSON 对象');
    }
    return Enrollment.fromJson(decoded);
  }

  Map<String, dynamic> toJson() => {
    'schema': schema,
    'product': 'Hampanel',
    'endpoint': endpoint,
    'ca_pem': caPem,
    'client_cert_pem': clientCertPem,
    'client_key_pem': clientKeyPem,
    'ca_sha256': caSha256,
    'server_sha256': serverSha256,
    'client_cn': clientCn,
    'created_at': createdAt,
  };

  static Directory configDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final base = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
      return Directory('$base\\Hampanel');
    }
    final base = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
    return Directory('$base/hampanel');
  }

  static File configFile() => File('${configDirectory().path}/enrollment.json');

  static Future<Enrollment?> load() async {
    try {
      final file = configFile();
      if (!await file.exists()) return null;
      return Enrollment.fromText(await file.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> save() async {
    final dir = configDirectory();
    await dir.create(recursive: true);
    final file = configFile();
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
    );
    if (!Platform.isWindows) {
      await Process.run('chmod', ['600', file.path]);
    }
  }

  static Future<void> clear() async {
    final file = configFile();
    if (await file.exists()) await file.delete();
  }
}
