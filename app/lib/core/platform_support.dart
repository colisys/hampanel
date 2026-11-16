import 'dart:io';

/// Capability switches for features that depend on desktop tools.
class PlatformSupport {
  PlatformSupport._();

  static bool get isMobile => Platform.isAndroid || Platform.isIOS;

  /// Port forwarding launches local `ssh`/`socat` processes.
  static bool get localTunnels => !isMobile;

  /// Opening a native file manager is desktop-only; Android users see the
  /// configuration path instead.
  static bool get openConfigDirectory => !isMobile;

  /// Desktop uses the OS keychain; mobile stores the key in the app sandbox.
  static bool get systemKeychain => !isMobile;

  /// File pickers/savers use the Android SAF bridge.
  static bool get nativeFileDialog => Platform.isAndroid;

  static String get name {
    if (Platform.isAndroid) return 'Android';
    if (Platform.isIOS) return 'iOS';
    if (Platform.isMacOS) return 'macOS';
    if (Platform.isWindows) return 'Windows';
    if (Platform.isLinux) return 'Linux';
    return Platform.operatingSystem;
  }
}
