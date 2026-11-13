import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../core/models/tunnel_profile.dart';

class TunnelRuntime {
  TunnelRuntime(this.profile);

  final TunnelProfile profile;
  Process? process;
  final StringBuffer logs = StringBuffer();
  bool running = false;
  bool exited = false;
  int? exitCode;
  String? error;
  void Function()? onChanged;

  void append(String text) {
    if (text.isEmpty) return;
    logs.write(text);
    if (logs.length > 60000) {
      final value = logs.toString();
      logs
        ..clear()
        ..write(value.substring(value.length - 50000));
    }
    onChanged?.call();
  }
}

class TunnelRunner {
  static Future<({bool available, String version})> checkSsh() async {
    try {
      final result = await Process.run('ssh', ['-V']);
      final version =
          ((result.stderr as String).isNotEmpty
                  ? result.stderr as String
                  : result.stdout as String)
              .trim();
      return (available: result.exitCode == 0, version: version);
    } catch (_) {
      return (available: false, version: '');
    }
  }

  static Future<({bool available, String version})> checkSocat() async {
    try {
      final result = await Process.run('socat', ['-V']);
      return (
        available: result.exitCode == 0,
        version: (result.stdout as String).trim(),
      );
    } catch (_) {
      return (available: false, version: '');
    }
  }

  static Future<TunnelRuntime> start(TunnelProfile profile) async {
    final runtime = TunnelRuntime(profile);
    try {
      validate(profile);
      final String executable;
      final List<String> arguments;
      if (profile.mode == 'socat') {
        executable = 'socat';
        arguments = [
          'TCP-LISTEN:${profile.localPort},fork,reuseaddr',
          'TCP:${profile.targetHost}:${profile.targetPort}',
        ];
      } else {
        executable = 'ssh';
        arguments = _sshArguments(profile);
      }
      final process = await Process.start(
        executable,
        arguments,
        runInShell: false,
      );
      runtime.process = process;
      process.stdout.transform(utf8.decoder).listen(runtime.append);
      process.stderr.transform(utf8.decoder).listen(runtime.append);
      process.exitCode.then((code) {
        runtime.exited = true;
        runtime.running = false;
        runtime.exitCode = code;
        runtime.append('\n[tunnel exited with code $code]\n');
        runtime.onChanged?.call();
      });
      await Future<void>.delayed(const Duration(milliseconds: 500));
      if (!runtime.exited) runtime.running = true;
    } catch (error) {
      runtime.error = error.toString();
      runtime.running = false;
    }
    return runtime;
  }

  static Future<void> stop(TunnelRuntime runtime) async {
    final process = runtime.process;
    runtime.running = false;
    if (process == null) return;
    try {
      process.kill(ProcessSignal.sigterm);
    } catch (_) {
      process.kill();
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      try {
        process.kill(ProcessSignal.sigkill);
      } catch (_) {
        process.kill();
      }
    }
  }

  static List<String> _sshArguments(TunnelProfile profile) {
    final arguments = <String>[
      '-N',
      '-o',
      'ExitOnForwardFailure=yes',
      '-o',
      'BatchMode=yes',
      '-o',
      'ServerAliveInterval=30',
      '-o',
      'ServerAliveCountMax=3',
      '-o',
      'StrictHostKeyChecking=accept-new',
      '-p',
      '${profile.sshPort}',
      '-l',
      profile.sshUser,
    ];
    if (profile.keyPath.trim().isNotEmpty) {
      arguments.addAll(['-i', _expandPath(profile.keyPath.trim())]);
    }
    if (profile.jumpHost.trim().isNotEmpty) {
      arguments.addAll(['-J', profile.jumpHost.trim()]);
    }
    switch (profile.mode) {
      case 'local':
        arguments.addAll([
          '-L',
          '127.0.0.1:${profile.localPort}:${profile.targetHost}:${profile.targetPort}',
        ]);
      case 'remote':
        arguments.addAll([
          '-R',
          '127.0.0.1:${profile.remotePort}:${profile.targetHost}:${profile.targetPort}',
        ]);
      case 'socks':
        arguments.addAll(['-D', '127.0.0.1:${profile.localPort}']);
      default:
        throw ArgumentError('未知隧道模式');
    }
    arguments.add(profile.sshHost);
    return arguments;
  }

  static void validate(TunnelProfile profile) {
    if (profile.name.trim().isEmpty) throw ArgumentError('名称不能为空');
    if (!const ['local', 'remote', 'socks', 'socat'].contains(profile.mode)) {
      throw ArgumentError('未知隧道模式');
    }
    if (profile.mode != 'socat') {
      if (!_validHost(profile.sshHost) || !_validUser(profile.sshUser)) {
        throw ArgumentError('SSH 主机或用户格式不正确');
      }
      if (profile.sshPort < 1 || profile.sshPort > 65535) {
        throw ArgumentError('SSH 端口必须是 1-65535');
      }
      if (profile.keyPath.contains('\n') || profile.keyPath.contains('\r')) {
        throw ArgumentError('私钥路径不合法');
      }
      if (!_validJump(profile.jumpHost.trim())) {
        throw ArgumentError('跳板机格式应为 [user@]host[:port]');
      }
    }
    if (profile.mode == 'socks') {
      if (profile.localPort < 1 || profile.localPort > 65535) {
        throw ArgumentError('本地端口必须是 1-65535');
      }
      return;
    }
    if (profile.mode == 'remote') {
      if (profile.remotePort < 1 || profile.remotePort > 65535) {
        throw ArgumentError('远端端口必须是 1-65535');
      }
    } else if (profile.localPort < 1 || profile.localPort > 65535) {
      throw ArgumentError('本地端口必须是 1-65535');
    }
    if (!_validHost(profile.targetHost)) {
      throw ArgumentError('目标主机格式不正确（暂不支持 IPv6 字面量）');
    }
    if (profile.targetPort < 1 || profile.targetPort > 65535) {
      throw ArgumentError('目标端口必须是 1-65535');
    }
  }

  static bool _validHost(String value) =>
      RegExp(r'^[A-Za-z0-9._-]{1,255}$').hasMatch(value.trim());

  static bool _validUser(String value) =>
      RegExp(r'^[A-Za-z0-9._-]{1,64}$').hasMatch(value.trim());

  static bool _validJump(String value) {
    if (value.isEmpty) return true;
    final match = RegExp(
      r'^([A-Za-z0-9._-]+@)?[A-Za-z0-9._-]+(:([0-9]{1,5}))?$',
    ).firstMatch(value);
    if (match == null) return false;
    final port = match.group(3);
    if (port != null) {
      final value = int.tryParse(port);
      if (value == null || value < 1 || value > 65535) return false;
    }
    return true;
  }

  static String _expandPath(String path) {
    if (path.startsWith('~/')) {
      final home = Platform.environment['HOME'];
      if (home != null && home.isNotEmpty) {
        return '$home${path.substring(1)}';
      }
    }
    return path;
  }
}
