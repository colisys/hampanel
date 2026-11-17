import 'dart:io';

import 'native_files.dart';

/// Opens a link in the platform browser. Android uses the SAF bridge;
/// desktops delegate to the system opener.
Future<bool> openExternalUrl(String url) async {
  if (NativeFiles.supported) {
    try {
      await NativeFiles.openUrl(url);
      return true;
    } catch (_) {
      return false;
    }
  }
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    } else {
      await Process.run('xdg-open', [url]);
    }
    return true;
  } catch (_) {
    return false;
  }
}
