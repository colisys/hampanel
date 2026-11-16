import 'dart:convert';
import 'dart:io';

import 'app_paths.dart';
import 'models/tunnel_profile.dart';

/// Tunnel profiles live on the management side. No secrets are stored.
class TunnelStore {
  static Directory _dir() => AppPaths.configDirectory();

  static File get _file =>
      File('${_dir().path}${Platform.pathSeparator}tunnels.json');

  static Future<List<TunnelProfile>> load() async {
    try {
      if (!await _file.exists()) return [];
      final raw = jsonDecode(await _file.readAsString());
      if (raw is! List) return [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(TunnelProfile.fromJson)
          .where((profile) => profile.id.isNotEmpty && profile.name.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<TunnelProfile> profiles) async {
    await _dir().create(recursive: true);
    await _file.writeAsString(
      jsonEncode([for (final profile in profiles) profile.toJson()]),
    );
    if (!Platform.isWindows) {
      await restrictToOwner(_file);
    }
  }

  static String newId() {
    final now = DateTime.now().millisecondsSinceEpoch;
    final random = now ^ (now >> 7) ^ (now << 11);
    return '$now-${random.toRadixString(16)}';
  }
}
