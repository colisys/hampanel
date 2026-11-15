import 'dart:io';

class KeychainException implements Exception {
  KeychainException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Stores the AI API key in the operating system keychain.
/// The key is never written to the panel's JSON configuration.
class AiKeychain {
  static const _service = 'work.dawncall.hampanel';
  static const _account = 'default';

  static Future<String?> readKey() async {
    try {
      if (Platform.isLinux) {
        final result = await Process.run('secret-tool', [
          'lookup',
          'service',
          _service,
          'account',
          _account,
        ]);
        if (result.exitCode != 0) return null;
        final value = (result.stdout as String).trim();
        return value.isEmpty ? null : value;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('security', [
          'find-generic-password',
          '-a',
          _account,
          '-s',
          _service,
          '-w',
        ]);
        if (result.exitCode != 0) return null;
        final value = (result.stdout as String).trim();
        return value.isEmpty ? null : value;
      }
      if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          _windowsReadScript,
        ]);
        if (result.exitCode != 0) return null;
        final value = (result.stdout as String).trim();
        return value.isEmpty ? null : value;
      }
      throw KeychainException('当前平台不支持系统钥匙串');
    } on ProcessException {
      throw KeychainException(_missingToolMessage());
    }
  }

  static Future<void> writeKey(String key) async {
    try {
      if (Platform.isLinux) {
        final process = await Process.start('secret-tool', [
          'store',
          '--label=Hampanel AI',
          'service',
          _service,
          'account',
          _account,
        ]);
        process.stdin.write(key);
        await process.stdin.close();
        final code = await process.exitCode;
        if (code != 0) throw KeychainException('无法写入系统钥匙串');
        return;
      }
      if (Platform.isMacOS) {
        final result = await Process.run('security', [
          'add-generic-password',
          '-U',
          '-a',
          _account,
          '-s',
          _service,
          '-w',
          key,
        ]);
        if (result.exitCode != 0) throw KeychainException('无法写入系统钥匙串');
        return;
      }
      if (Platform.isWindows) {
        final result = await Process.run(
          'powershell.exe',
          ['-NoProfile', '-NonInteractive', '-Command', _windowsWriteScript],
          environment: {'HAMPANEL_AI_KEY': key},
        );
        if (result.exitCode != 0) throw KeychainException('无法写入 Windows 凭据管理器');
        return;
      }
      throw KeychainException('当前平台不支持系统钥匙串');
    } on ProcessException {
      throw KeychainException(_missingToolMessage());
    }
  }

  static Future<void> deleteKey() async {
    try {
      if (Platform.isLinux) {
        await Process.run('secret-tool', [
          'clear',
          'service',
          _service,
          'account',
          _account,
        ]);
        return;
      }
      if (Platform.isMacOS) {
        await Process.run('security', [
          'delete-generic-password',
          '-a',
          _account,
          '-s',
          _service,
        ]);
        return;
      }
      if (Platform.isWindows) {
        await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          _windowsDeleteScript,
        ]);
        return;
      }
    } on ProcessException {
      throw KeychainException(_missingToolMessage());
    }
  }

  static String _missingToolMessage() {
    if (Platform.isLinux) {
      return '系统钥匙串不可用：请安装 libsecret-tools（提供 secret-tool）并确保桌面钥匙环已解锁。';
    }
    return '系统钥匙串不可用，请检查系统凭据服务。';
  }

  static const _windowsReadScript = '''
[Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime] > \$null
\$vault = New-Object Windows.Security.Credentials.PasswordVault
try {
  \$cred = \$vault.Retrieve('work.dawncall.hampanel', 'default')
  \$cred.RetrievePassword()
  Write-Output \$cred.Password
} catch { exit 1 }
''';

  static const _windowsWriteScript = '''
[Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime] > \$null
\$vault = New-Object Windows.Security.Credentials.PasswordVault
try { \$old = \$vault.Retrieve('work.dawncall.hampanel', 'default'); \$vault.Remove(\$old) } catch {}
\$cred = New-Object Windows.Security.Credentials.PasswordCredential('work.dawncall.hampanel', 'default', \$env:HAMPANEL_AI_KEY)
\$vault.Add(\$cred)
''';

  static const _windowsDeleteScript = '''
[Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime] > \$null
\$vault = New-Object Windows.Security.Credentials.PasswordVault
try { \$old = \$vault.Retrieve('work.dawncall.hampanel', 'default'); \$vault.Remove(\$old) } catch {}
''';
}
