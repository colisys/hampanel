import 'dart:convert';
import 'dart:io';

import 'build_info.dart';

enum ClientUpdateChannel { stable, nightly }

extension ClientUpdateChannelLabel on ClientUpdateChannel {
  String get wire => name;

  String get label => switch (this) {
    ClientUpdateChannel.stable => 'stable',
    ClientUpdateChannel.nightly => 'nightly',
  };
}

class ClientRelease {
  const ClientRelease({
    required this.tag,
    required this.version,
    required this.notes,
    required this.publishedAt,
    required this.prerelease,
    required this.assets,
  });

  final String tag;
  final String version;
  final String notes;
  final DateTime? publishedAt;
  final bool prerelease;
  final List<Map<String, dynamic>> assets;

  String? assetUrl(String name) {
    for (final asset in assets) {
      if (asset['name'] == name) {
        return (asset['browser_download_url'] as String?)?.trim();
      }
    }
    return null;
  }
}

/// 管理端自身的更新检查：先选择 stable/nightly 通道，再查询 GitHub Release。
class ClientUpdateService {
  const ClientUpdateService({this.repo = 'colisys/hampanel'});

  final String repo;

  Future<ClientRelease> fetch(
    ClientUpdateChannel channel, {
    String mirror = '',
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15)
      ..idleTimeout = const Duration(seconds: 20);
    try {
      final path = channel == ClientUpdateChannel.nightly
          ? '/repos/$repo/releases/tags/nightly'
          : '/repos/$repo/releases/latest';
      final url = withMirror('https://api.github.com$path', mirror);
      final json = await _getJson(client, url);
      final assets = <Map<String, dynamic>>[];
      for (final raw in (json['assets'] as List?) ?? const []) {
        if (raw is Map) assets.add(raw.cast<String, dynamic>());
      }
      var version = (json['tag_name'] as String?)?.trim() ?? '';
      final versionUrl = _assetNamed(assets, 'version.txt');
      if (versionUrl != null) {
        try {
          final text = await _getText(client, withMirror(versionUrl, mirror));
          final trimmed = text.trim();
          if (trimmed.contains('.')) version = trimmed;
        } catch (_) {
          // 版本文件不可用时退回 tag。
        }
      }
      if (version.startsWith('v')) version = version.substring(1);
      return ClientRelease(
        tag: (json['tag_name'] as String?) ?? '',
        version: version,
        notes: (json['body'] as String?) ?? '',
        publishedAt: DateTime.tryParse((json['published_at'] as String?) ?? ''),
        prerelease: json['prerelease'] == true,
        assets: assets,
      );
    } finally {
      client.close(force: true);
    }
  }

  /// GitHub 镜像接受完整上游 URL 作为路径，本方法保证只拼接一次。
  static String withMirror(String url, String mirror) {
    final base = mirror.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) return url;
    if (url.startsWith(base)) return url;
    return '$base/$url';
  }

  static int compareVersions(String a, String b) {
    final left = a.split(RegExp(r'[+-]')).first.split('.');
    final right = b.split(RegExp(r'[+-]')).first.split('.');
    final length = left.length > right.length ? left.length : right.length;
    for (var i = 0; i < length; i++) {
      final lv = i < left.length ? int.tryParse(left[i].trim()) ?? 0 : 0;
      final rv = i < right.length ? int.tryParse(right[i].trim()) ?? 0 : 0;
      if (lv != rv) return lv < rv ? -1 : 1;
    }
    return 0;
  }

  /// nightly 通道在版本号相同但提交不同时视为有更新；stable 只看版本号。
  static bool isNewer({
    required ClientUpdateChannel channel,
    required String remoteVersion,
    required String localVersion,
    required String localCommit,
  }) {
    final order = compareVersions(remoteVersion, localVersion);
    if (order != 0) return order > 0;
    if (channel != ClientUpdateChannel.nightly) return false;
    final remoteCommit = commitOf(remoteVersion);
    if (remoteCommit.isEmpty || remoteCommit == 'unknown') return false;
    if (localCommit.isEmpty || localCommit == 'unknown') return false;
    return remoteCommit != localCommit;
  }

  static String commitOf(String version) {
    final plus = version.indexOf('+');
    if (plus < 0 || plus == version.length - 1) return '';
    return version.substring(plus + 1).split('.').first;
  }

  static String? clientAsset(
    ClientRelease release, {
    String? operatingSystem,
    String? architecture,
  }) {
    final os = operatingSystem ?? Platform.operatingSystem;
    final arch = architecture ?? _arch();
    for (final asset in release.assets) {
      final name = (asset['name'] as String?) ?? '';
      final matches = switch (os) {
        'linux' => name.contains('client-linux-x86_64'),
        'windows' => name.contains('client-windows-x86_64'),
        'macos' => name.contains('client-macos-') && name.contains(arch),
        'android' => name.contains('android') && name.endsWith('.apk'),
        'ios' => name.contains('ios') && name.endsWith('.ipa'),
        _ => false,
      };
      if (matches) {
        return (asset['browser_download_url'] as String?)?.trim();
      }
    }
    return null;
  }

  static String _arch() {
    if (Platform.isMacOS) {
      return Platform.version.contains('arm64') ? 'arm64' : 'x86_64';
    }
    return 'x86_64';
  }

  static String? _assetNamed(List<Map<String, dynamic>> assets, String name) {
    for (final asset in assets) {
      if (asset['name'] == name) {
        return (asset['browser_download_url'] as String?)?.trim();
      }
    }
    return null;
  }

  Future<Map<String, dynamic>> _getJson(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('Accept', 'application/vnd.github+json');
    request.headers.set('User-Agent', 'Hampanel/$fullClientVersion');
    final response = await request.close().timeout(const Duration(seconds: 25));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw ClientUpdateException(
        'GitHub API ${response.statusCode}: ${_short(body)}',
      );
    }
    final decoded = jsonDecode(body);
    if (decoded is Map) return decoded.cast<String, dynamic>();
    throw const ClientUpdateException('GitHub 返回了无法解析的数据');
  }

  Future<String> _getText(HttpClient client, String url) async {
    final request = await client.getUrl(Uri.parse(url));
    request.headers.set('User-Agent', 'Hampanel/$fullClientVersion');
    final response = await request.close().timeout(const Duration(seconds: 25));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw ClientUpdateException('HTTP ${response.statusCode}');
    }
    return body;
  }

  static String _short(String value) =>
      value.length <= 120 ? value : '${value.substring(0, 120)}…';
}

class ClientUpdateException implements Exception {
  const ClientUpdateException(this.message);

  final String message;

  @override
  String toString() => message;
}
