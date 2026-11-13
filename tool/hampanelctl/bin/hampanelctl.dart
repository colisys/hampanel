// Hampanel deployment CLI (no third-party dependencies).
// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

void main(List<String> args) async {
  if (args.isEmpty || args.first == '--help' || args.first == '-h') {
    _usage();
    exit(args.isEmpty ? 2 : 0);
  }
  if (args.first != 'deploy') {
    stderr.writeln('[hampanelctl] unknown command: ${args.first}');
    _usage();
    exit(2);
  }

  final options = _Options.parse(args.sublist(1));
  if (options == null) exit(2);

  try {
    await _deploy(options);
  } catch (error) {
    stderr.writeln('[hampanelctl] ${error}');
    exit(1);
  }
}

class _Options {
  String host = '';
  String user = 'root';
  int sshPort = 22;
  String? identity;
  String source = Directory.current.path;
  String endpoint = '';
  List<String> sans = [];
  String? out;
  int? panelPort;
  String? entryPrefix;
  String remoteDir = '/tmp/hampanel-src';
  bool local = false;
  bool sudo = false;
  bool noSystemd = false;
  bool noStart = false;
  String os = 'linux';
  String? prefix;
  String? configDir;
  String? dataDir;
  String? tlsDir;
  String? enrollFile;
  String? openSslDir;
  bool installDriver = false;

  static _Options? parse(List<String> args) {
    final options = _Options();
    var index = 0;

    String value(String flag) {
      index++;
      if (index >= args.length) {
        throw FormatException('missing value for $flag');
      }
      return args[index];
    }

    try {
      while (index < args.length) {
        final arg = args[index];
        switch (arg) {
          case '--host':
            options.host = value(arg);
          case '--user':
            options.user = value(arg);
          case '--ssh-port':
            options.sshPort = int.parse(value(arg));
          case '--identity':
            options.identity = value(arg);
          case '--source':
            options.source = value(arg);
          case '--endpoint':
            options.endpoint = value(arg);
          case '--san':
            options.sans.add(value(arg));
          case '--out':
            options.out = value(arg);
          case '--panel-port':
            options.panelPort = int.parse(value(arg));
          case '--entry-prefix':
            options.entryPrefix = value(arg);
          case '--remote-dir':
            options.remoteDir = value(arg);
          case '--os':
            options.os = value(arg);
          case '--prefix':
            options.prefix = value(arg);
          case '--config-dir':
            options.configDir = value(arg);
          case '--data-dir':
            options.dataDir = value(arg);
          case '--tls-dir':
            options.tlsDir = value(arg);
          case '--enroll-file':
            options.enrollFile = value(arg);
          case '--openssl-dir':
            options.openSslDir = value(arg);
          case '--local':
            options.local = true;
          case '--sudo':
            options.sudo = true;
          case '--no-systemd':
            options.noSystemd = true;
          case '--no-start':
            options.noStart = true;
          case '--install-driver':
            options.installDriver = true;
          case '--help':
          case '-h':
            _usage();
            exit(0);
          default:
            throw FormatException('unknown option: $arg');
        }
        index++;
      }
    } on FormatException catch (error) {
      stderr.writeln('[hampanelctl] ${error.message}');
      _usage();
      return null;
    }

    if (!options.local && options.host.isEmpty) {
      stderr.writeln('[hampanelctl] --host is required (or use --local)');
      return null;
    }
    if (options.endpoint.isEmpty) {
      options.endpoint = options.panelPort != null
          ? '${options.host}:${options.panelPort}'
          : options.host;
    }
    if (options.out == null) {
      options.out = 'hampanel-${options.local ? 'local' : options.host}.json';
    }
    return options;
  }
}

Future<void> _deploy(_Options options) async {
  final source = Directory(options.source);
  if (!Directory('${source.path}/daemon').existsSync()) {
    throw '--source must point at the Hampanel repository root';
  }

  if (options.local) {
    await _deployLocal(options, source);
    return;
  }

  if (options.os == 'windows') {
    await _deployWindows(options, source);
    return;
  }
  await _deployLinux(options, source);
}

Future<void> _deployLocal(_Options options, Directory source) async {
  final arguments = <String>[
    '${source.path}/deploy/bootstrap.sh',
    '--source',
    source.path,
    '--endpoint',
    options.endpoint,
  ];
  if (options.panelPort != null)
    arguments.addAll(['--port', '${options.panelPort}']);
  if (options.entryPrefix != null)
    arguments.addAll(['--entry-prefix', options.entryPrefix!]);
  if (options.prefix != null) arguments.addAll(['--prefix', options.prefix!]);
  if (options.configDir != null)
    arguments.addAll(['--config-dir', options.configDir!]);
  if (options.dataDir != null)
    arguments.addAll(['--data-dir', options.dataDir!]);
  if (options.tlsDir != null) arguments.addAll(['--tls-dir', options.tlsDir!]);
  if (options.enrollFile != null)
    arguments.addAll(['--enroll-file', options.enrollFile!]);
  if (options.noSystemd || Platform.environment['USER'] != 'root') {
    arguments.add('--no-systemd');
  }
  if (options.noStart) arguments.add('--no-start');
  for (final san in options.sans) {
    arguments.addAll(['--san', san]);
  }

  _step('running local bootstrap');
  final result = await Process.run('bash', arguments);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw 'bootstrap failed with exit code ${result.exitCode}';
  }

  final match = RegExp(r'\[hampanel\] enrollment: (.+)')
      .firstMatch(result.stderr.toString());
  if (match == null) throw 'could not locate the enrollment bundle path';
  await _storeEnrollment(match.group(1)!.trim(), options.out!);
}

Future<void> _deployLinux(_Options options, Directory source) async {
  final archive =
      '${Directory.systemTemp.path}/hampanel-src-${DateTime.now().microsecondsSinceEpoch}.tgz';
  _step('packing source');
  final tar = await Process.run('tar', [
    '-czf',
    archive,
    '--exclude=.git',
    '--exclude=.zig-cache',
    '--exclude=zig-out',
    '--exclude=app',
    '--exclude=.dart_tool',
    '-C',
    source.path,
    '.',
  ]);
  if (tar.exitCode != 0) throw 'tar failed: ${tar.stderr}';

  final target = '${options.user}@${options.host}';
  _step('uploading archive to $target:${options.remoteDir}');
  final scpArgs = ['-P', '${options.sshPort}'];
  if (options.identity != null) scpArgs.addAll(['-i', options.identity!]);
  scpArgs.addAll([
    '-o',
    'StrictHostKeyChecking=accept-new',
    archive,
    '$target:/tmp/hampanel-src.tgz'
  ]);
  await _run('scp', scpArgs);

  _step('extracting on remote host');
  await _ssh(options, [
    'rm -rf ${options.remoteDir} /tmp/hampanel-src && '
        'mkdir -p ${options.remoteDir} && '
        'tar -xzf /tmp/hampanel-src.tgz -C ${options.remoteDir}',
  ]);

  final bootstrapArgs = <String>[
    'bash',
    '${options.remoteDir}/deploy/bootstrap.sh',
    '--source',
    options.remoteDir,
    '--endpoint',
    options.endpoint,
  ];
  if (options.panelPort != null)
    bootstrapArgs.addAll(['--port', '${options.panelPort}']);
  if (options.entryPrefix != null)
    bootstrapArgs.addAll(['--entry-prefix', options.entryPrefix!]);
  if (options.tlsDir != null)
    bootstrapArgs.addAll(['--tls-dir', options.tlsDir!]);
  if (options.enrollFile != null)
    bootstrapArgs.addAll(['--enroll-file', options.enrollFile!]);
  for (final san in options.sans) {
    bootstrapArgs.addAll(['--san', san]);
  }
  if (options.noStart) bootstrapArgs.add('--no-start');

  final command = <String>[
    if (options.sudo || options.user != 'root') 'sudo',
    ...bootstrapArgs,
  ].join(' ');

  _step('building and installing on remote host (this may take a few minutes)');
  await _ssh(options, [command]);

  _step('fetching enrollment bundle');
  final remoteEnroll = options.enrollFile ??
      (options.configDir != null
          ? '${options.configDir}/enroll.json'
          : '/etc/hampanel/enroll.json');
  final cat =
      '${options.sudo || options.user != 'root' ? 'sudo ' : ''}cat $remoteEnroll';
  final enrollment = await _ssh(options, [cat], capture: true);
  await _writeEnrollment(enrollment, options.out!);
}

Future<void> _deployWindows(_Options options, Directory source) async {
  final archive =
      '${Directory.systemTemp.path}/hampanel-src-${DateTime.now().microsecondsSinceEpoch}.tgz';
  _step('packing source');
  final tar = await Process.run('tar', [
    '-czf',
    archive,
    '--exclude=.git',
    '--exclude=.zig-cache',
    '--exclude=zig-out',
    '--exclude=app',
    '-C',
    source.path,
    '.',
  ]);
  if (tar.exitCode != 0) throw 'tar failed: ${tar.stderr}';

  final target = '${options.user}@${options.host}';
  final scpArgs = ['-P', '${options.sshPort}'];
  if (options.identity != null) scpArgs.addAll(['-i', options.identity!]);
  scpArgs.addAll([
    '-o',
    'StrictHostKeyChecking=accept-new',
    archive,
    '$target:C:/ProgramData/hampanel/src.tgz'
  ]);
  _step('uploading archive to $target');
  await _run('scp', scpArgs);

  await _ssh(options, [
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "'
        "New-Item -ItemType Directory -Force -Path 'C:\\ProgramData\\hampanel\\src' | Out-Null; "
        "tar -xzf 'C:\\ProgramData\\hampanel\\src.tgz' -C 'C:\\ProgramData\\hampanel\\src'\"",
  ]);

  final installArgs = <String>[
    '-Source',
    r'C:\ProgramData\hampanel\src',
    '-Endpoint',
    options.endpoint,
  ];
  if (options.panelPort != null)
    installArgs.addAll(['-Port', '${options.panelPort}']);
  if (options.entryPrefix != null)
    installArgs.addAll(['-EntryPrefix', options.entryPrefix!]);
  for (final san in options.sans) {
    installArgs.addAll(['-San', san]);
  }
  if (options.openSslDir != null)
    installArgs.addAll(['-OpenSslDir', options.openSslDir!]);
  if (options.installDriver) installArgs.add('-InstallDriver');

  final escaped = installArgs
      .map((value) => value.contains(' ') ? "'$value'" : value)
      .join(' ');
  _step('building and installing Windows service');
  await _ssh(options, [
    'powershell -NoProfile -ExecutionPolicy Bypass -File '
            r'C:\ProgramData\hampanel\src\deploy\windows\install.ps1 ' +
        escaped,
  ]);

  _step('fetching enrollment bundle');
  final enrollment = await _ssh(
      options,
      [
        r'powershell -NoProfile -Command "Get-Content C:\ProgramData\hampanel\enroll.json -Raw"',
      ],
      capture: true);
  await _writeEnrollment(enrollment, options.out!);
}

Future<String> _ssh(_Options options, List<String> commands,
    {bool capture = false}) async {
  final args = [
    '-p',
    '${options.sshPort}',
    '-o',
    'StrictHostKeyChecking=accept-new'
  ];
  if (options.identity != null) args.addAll(['-i', options.identity!]);
  args.add('${options.user}@${options.host}');
  args.addAll(commands);
  final result = await Process.run('ssh', args);
  if (!capture) {
    stdout.write(result.stdout);
    stderr.write(result.stderr);
  }
  if (result.exitCode != 0) {
    throw 'ssh command failed (${result.exitCode}): ${commands.join(' ')}\n${result.stderr}';
  }
  return result.stdout.toString();
}

Future<void> _run(String command, List<String> args) async {
  final result = await Process.run(command, args);
  if (result.exitCode != 0) {
    throw '$command failed: ${result.stderr}';
  }
}

Future<void> _storeEnrollment(String path, String outPath) async {
  final file = File(path);
  if (!file.existsSync()) throw 'enrollment file not found: $path';
  await _writeEnrollment(await file.readAsString(), outPath);
}

Future<void> _writeEnrollment(String content, String outPath) async {
  final file = File(outPath);
  await file.parent.create(recursive: true);
  await file.writeAsString(content);
  if (!Platform.isWindows) {
    await Process.run('chmod', ['600', file.path]);
  }
  stdout.writeln('[hampanelctl] enrollment written to ${file.path}');
}

void _step(String message) => stdout.writeln('[hampanelctl] $message');

void _usage() {
  stdout.writeln('''
Hampanel deployment CLI

Usage:
  dart run tool/hampanelctl/bin/hampanelctl.dart deploy [options]

Required:
  --host <host>            remote host (omit with --local)
  --endpoint <host:port>   public panel endpoint (default: <host>:8443)

Options:
  --user <name>            SSH user (default: root)
  --ssh-port <port>        SSH port (default: 22)
  --identity <path>        SSH private key
  --source <path>          repository root (default: current directory)
  --san <host|ip>          extra certificate SAN (repeatable)
  --endpoint may omit the port; the daemon then picks a free port.
  --panel-port <port>      daemon port (default: random free port)
  --entry-prefix <path>    secret entry prefix (default: random /token)
  --out <path>             enrollment output (default: hampanel-<host>.json)
  --config-dir <path>      remote config directory
  --data-dir <path>        remote data directory
  --tls-dir <path>         remote PKI directory
  --enroll-file <path>     remote enrollment path
  --sudo                   run the remote bootstrap with sudo
  --no-start               install without starting the service
  --local                  build and install on this machine (no SSH)
  --os <linux|windows>     remote platform (default: linux)
  --openssl-dir <path>     OpenSSL prefix for Windows builds
  --install-driver         install the Windows kernel companion driver

Examples:
  dart run tool/hampanelctl/bin/hampanelctl.dart deploy --host 203.0.113.10 \\
      --san 203.0.113.10 --out hampanel-prod.json

  dart run tool/hampanelctl/bin/hampanelctl.dart deploy --local --no-systemd \\
      --endpoint 127.0.0.1:8443 --san 127.0.0.1
''');
}
