import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';

import 'enrollment.dart';

/// Connection and install options for the SSH onboarding wizard.
class SshInstallRequest {
  const SshInstallRequest({
    required this.host,
    this.port = 22,
    required this.username,
    this.password,
    this.privateKeyPath,
    this.privateKeyPassphrase,
    this.endpoint,
    this.mode = 'binary',
    this.channel = 'stable',
    this.sourceRef = 'nightly',
    this.panelPort,
    this.mirror,
    this.githubMirror,
    this.alias,
    this.extraSans = const [],
  });

  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKeyPath;
  final String? privateKeyPassphrase;
  final String? endpoint;
  final String mode;
  final String channel;
  final String sourceRef;
  final int? panelPort;
  final String? mirror;
  final String? githubMirror;
  final String? alias;
  final List<String> extraSans;

  String get effectiveEndpoint {
    final value = endpoint?.trim() ?? '';
    return value.isEmpty ? host : value;
  }
}

/// Installs hampaneld on a remote Linux or Windows host over SSH by running the
/// published installer script, then returns the enrollment bundle.
class SshInstaller {
  static const _repo = 'colisys/hampanel';

  Future<Enrollment> install(
    SshInstallRequest request, {
    required void Function(String) onLog,
  }) async {
    onLog('连接 ${request.host}:${request.port} ...');
    final socket = await SSHSocket.connect(
      request.host,
      request.port,
      timeout: const Duration(seconds: 20),
    );

    List<SSHKeyPair>? identities;
    final keyPath = request.privateKeyPath?.trim();
    if (keyPath != null && keyPath.isNotEmpty) {
      final pem = await File(keyPath).readAsString();
      identities = SSHKeyPair.fromPem(pem, request.privateKeyPassphrase);
    }

    final client = SSHClient(
      socket,
      username: request.username,
      identities: identities,
      onPasswordRequest: request.password == null
          ? null
          : () => request.password,
      onVerifyHostKey: (type, fingerprint) {
        final text = utf8.decode(fingerprint, allowMalformed: true);
        onLog('主机密钥 $type: ${text.isEmpty ? _hex(fingerprint) : text}');
        return true;
      },
    );

    try {
      await client.authenticated;
      onLog('SSH 认证成功');

      final platform = await _detectPlatform(client, onLog);
      var sudo = false;
      if (platform == 'linux') {
        final id = await client.runWithResult('id -u');
        final uid = utf8.decode(id.output, allowMalformed: true).trim();
        if (uid != '0') {
          final probe = await client.runWithResult('sudo -n true');
          if (probe.exitCode != 0) {
            throw '需要 root 登录，或为 ${request.username} 配置免密 sudo';
          }
          sudo = true;
        }
      }

      final command = platform == 'windows'
          ? _windowsCommand(request)
          : _linuxCommand(request, sudo);
      onLog(
        '开始安装（${request.mode == 'binary' ? '发布二进制' : '源码构建'}，'
        '${request.channel}）...',
      );
      final exitCode = await _runStreaming(client, command, onLog);
      if (exitCode != 0) {
        throw '远程安装失败（退出码 $exitCode）';
      }

      onLog('读取注册凭据 ...');
      final text = await _readEnrollment(client, platform, sudo);
      return Enrollment.fromText(text);
    } finally {
      client.close();
    }
  }

  Future<String> _detectPlatform(
    SSHClient client,
    void Function(String) onLog,
  ) async {
    try {
      final result = await client.runWithResult('uname -s');
      final text = utf8.decode(result.output, allowMalformed: true).trim();
      if (result.exitCode == 0 && text.toLowerCase().contains('linux')) {
        return 'linux';
      }
    } catch (_) {
      // fall through to the Windows probe
    }
    try {
      final result = await client.runWithResult('cmd /c echo %OS%');
      final text = utf8.decode(result.output, allowMalformed: true);
      if (text.toLowerCase().contains('windows')) return 'windows';
    } catch (_) {
      // fall through
    }
    onLog('无法识别远程系统');
    throw '仅支持 Linux 和 Windows 主机';
  }

  String _linuxCommand(SshInstallRequest request, bool sudo) {
    final url = '${_releaseBase(request)}/hampanel-install-linux.sh';
    final args = <String>[
      '--mode',
      request.mode,
      '--channel',
      request.channel,
      '--repo',
      _repo,
      '--endpoint',
      request.effectiveEndpoint,
      if (request.mode == 'source') ...['--ref', request.sourceRef],
      if (request.panelPort != null) ...['--port', '${request.panelPort}'],
      if (request.mirror != null && request.mirror!.isNotEmpty) ...[
        '--mirror',
        request.mirror!,
      ],
      if (request.githubMirror != null &&
          request.githubMirror!.trim().isNotEmpty) ...[
        '--github-mirror',
        request.githubMirror!.trim(),
      ],
      for (final san in request.extraSans) ...['--san', san],
    ];
    final override = _releaseOverride;
    final runner = sudo
        ? (override == null
              ? 'sudo -n '
              : 'sudo -n env HAMPANEL_RELEASE_BASE=${_shellQuote(override)} ')
        : (override == null
              ? ''
              : 'env HAMPANEL_RELEASE_BASE=${_shellQuote(override)} ');
    return 'set -e\n'
        'tmp="\$(mktemp)"\n'
        'curl -fsSL -A ${_shellQuote(linuxUserAgent)} ${_shellQuote(url)} -o "\$tmp"\n'
        '${runner}bash "\$tmp" ${args.map(_shellQuote).join(' ')}\n';
  }

  String _windowsCommand(SshInstallRequest request) {
    final url = '${_releaseBase(request)}/hampanel-install-windows.ps1';
    final args = <String>[
      '-Mode',
      request.mode,
      '-Channel',
      request.channel,
      '-Repo',
      _repo,
      '-Endpoint',
      request.effectiveEndpoint,
      if (_releaseOverride != null) ...['-ReleaseBase', _releaseOverride!],
      if (request.mode == 'source') ...['-Ref', request.sourceRef],
      if (request.panelPort != null) ...['-Port', '${request.panelPort}'],
      if (request.githubMirror != null &&
          request.githubMirror!.trim().isNotEmpty) ...[
        '-GithubMirror',
        request.githubMirror!.trim(),
      ],
      for (final san in request.extraSans) ...['-San', san],
    ];
    final script =
        '''
\$ErrorActionPreference = 'Stop'
\$dir = 'C:\\ProgramData\\hampanel'
New-Item -ItemType Directory -Force -Path \$dir | Out-Null
Invoke-WebRequest -UseBasicParsing -Uri '${_psQuote(url)}' -OutFile "\$dir\\install.ps1" -UserAgent '${_psQuote(windowsUserAgent)}'
& "\$dir\\install.ps1" ${args.map((value) => "'${_psQuote(value)}'").join(' ')}
''';
    final encoded = base64Encode(_utf16le(script));
    return 'powershell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded';
  }

  Future<String> _readEnrollment(
    SSHClient client,
    String platform,
    bool sudo,
  ) async {
    final command = platform == 'windows'
        ? r'powershell -NoProfile -Command "Get-Content C:\ProgramData\hampanel\enroll.json -Raw"'
        : '${sudo ? 'sudo -n ' : ''}cat /etc/hampanel/enroll.json';
    final result = await client.runWithResult(command);
    final text = utf8.decode(result.output, allowMalformed: true).trim();
    if (result.exitCode != 0 || !text.startsWith('{')) {
      throw '无法读取远程注册凭据（exit ${result.exitCode}）';
    }
    return text;
  }

  Future<int> _runStreaming(
    SSHClient client,
    String command,
    void Function(String) onLog,
  ) async {
    final session = await client.execute(command);
    final stdout = _LineBuffer(onLog);
    final stderr = _LineBuffer(onLog);
    final subscriptions = <StreamSubscription<Uint8List>>[
      session.stdout.listen(stdout.add),
      session.stderr.listen(stderr.add),
    ];
    try {
      await session.done;
    } finally {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    }
    stdout.flush();
    stderr.flush();
    return session.exitCode ?? -1;
  }

  String _releaseBase(SshInstallRequest request) {
    final override = _releaseOverride;
    if (override != null) return override;
    final base = request.channel == 'stable' || request.channel == 'latest'
        ? 'https://github.com/$_repo/releases/latest/download'
        : 'https://github.com/$_repo/releases/download/${request.channel}';
    return _mirrorUrl(base, request.githubMirror);
  }

  String? get _releaseOverride {
    final value = Platform.environment['HAMPANEL_RELEASE_BASE'];
    return (value == null || value.isEmpty) ? null : value;
  }
}

class _LineBuffer {
  _LineBuffer(this.onLine);

  final void Function(String) onLine;
  final StringBuffer _pending = StringBuffer();

  void add(Uint8List bytes) {
    _pending.write(utf8.decode(bytes, allowMalformed: true));
    var text = _pending.toString();
    var newline = text.indexOf('\n');
    while (newline >= 0) {
      final line = text.substring(0, newline).replaceAll('\r', '');
      if (line.isNotEmpty) onLine(line);
      text = text.substring(newline + 1);
      newline = text.indexOf('\n');
    }
    _pending
      ..clear()
      ..write(text);
  }

  void flush() {
    final line = _pending.toString().trimRight();
    if (line.isNotEmpty) onLine(line);
    _pending.clear();
  }
}

String _hex(Uint8List bytes) =>
    bytes.map((value) => value.toRadixString(16).padLeft(2, '0')).join();

/// GitHub mirrors are frequently fronted by Cloudflare, which rejects
/// default curl / PowerShell agents with 403 — present as a browser.
const linuxUserAgent =
    'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';
const windowsUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36';

String _mirrorUrl(String url, String? mirror) {
  final value = mirror?.trim() ?? '';
  if (value.isEmpty) return url;
  final base = value.replaceFirst(RegExp(r'/+$'), '');
  if (base.isEmpty) return url;
  return '$base/$url';
}

String _shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _psQuote(String value) => value.replaceAll("'", "''");

Uint8List _utf16le(String value) {
  final units = value.codeUnits;
  final bytes = Uint8List(units.length * 2);
  for (var i = 0; i < units.length; i++) {
    bytes[i * 2] = units[i] & 0xff;
    bytes[i * 2 + 1] = (units[i] >> 8) & 0xff;
  }
  return bytes;
}
