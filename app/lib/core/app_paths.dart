import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Resolves the client's configuration directory.
///
/// Desktop keeps the historical `~/.config/hampanel` (or `%APPDATA%\Hampanel`)
/// location. Android and iOS have no usable `HOME`, so the app support
/// directory provided by the platform is used instead.
class AppPaths {
  AppPaths._();

  static Directory? _configDir;
  static Future<void>? _pending;

  /// Must be awaited before the first [configDirectory] call on mobile.
  /// Idempotent and safe to call from bootstrap retries.
  static Future<void> init() {
    return _pending ??= _init();
  }

  static Future<void> _init() async {
    Directory directory;
    if (Platform.isAndroid || Platform.isIOS) {
      try {
        final support = await getApplicationSupportDirectory();
        directory = Directory('${support.path}/hampanel');
      } catch (_) {
        directory = Directory(
          '${Directory.systemTemp.path}${Platform.pathSeparator}hampanel',
        );
      }
    } else {
      directory = desktopDirectory();
    }
    try {
      await directory.create(recursive: true);
      await restrictDirectoryToOwner(directory);
    } catch (_) {
      // Fall back to the temp directory when the preferred location is not
      // writable (for example a sandboxed or read-only home).
      directory = Directory(
        '${Directory.systemTemp.path}${Platform.pathSeparator}hampanel',
      );
      await directory.create(recursive: true);
    }
    _configDir = directory;
  }

  static Directory configDirectory() => _configDir ?? desktopDirectory();

  static Directory desktopDirectory() {
    final env = Platform.environment;
    if (Platform.isWindows) {
      final base = env['APPDATA'] ?? env['USERPROFILE'] ?? '.';
      return Directory('$base\\Hampanel');
    }
    final base = env['XDG_CONFIG_HOME'] ?? '${env['HOME'] ?? '.'}/.config';
    return Directory('$base/hampanel');
  }
}

/// `chmod 600` is meaningless (or unavailable) on Windows and mobile
/// sandboxes; desktop Unix keeps the existing hardening.
Future<void> restrictToOwner(File file) async {
  if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
  try {
    await Process.run('chmod', ['600', file.path]);
  } catch (_) {
    // chmod is best effort; the file lives in the user's config directory.
  }
}

/// Keeps the configuration directory private on desktop Unix; the stored
/// bundles contain client private keys and the AI key lives there too.
Future<void> restrictDirectoryToOwner(Directory directory) async {
  if (Platform.isWindows || Platform.isAndroid || Platform.isIOS) return;
  try {
    await Process.run('chmod', ['700', directory.path]);
  } catch (_) {
    // Best effort, same as restrictToOwner.
  }
}
