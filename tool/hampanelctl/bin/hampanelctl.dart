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
  String mode = 'binary';
  String channel = 'stable';
  String repo = 'colisys/hampanel';
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
          case '--mode':
            options.mode = value(arg);
          case '--channel':
            options.channel = value(arg);
          case '--repo':
            options.repo = value(arg);
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
    if (options.mode != 'binary' && options.mode != 'source') {
      stderr.writeln('[hampanelctl] --mode must be binary or source');
      return null;
    }
    if (options.out == null) {
      options.out = 'hampanel-${options.local ? 'local' : options.host}.json';
    }
    return options;
  }
}

Future<void> _deploy(_Options options) async {
  final source = Directory(options.source);
  final needsSource = options.local || options.mode == 'source';
  if (needsSource && !Directory('${source.path}/daemon').existsSync()) {
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
  final script = options.mode == 'binary'
      ? '${source.path}/deploy/install.sh'
      : '${source.path}/deploy/bootstrap.sh';
  final arguments = <String>[
    script,
    '--mode',
    options.mode,
    '--endpoint',
    options.endpoint,
  ];
  if (options.mode == 'binary') {
    arguments.addAll(['--channel', options.channel, '--repo', options.repo]);
  } else {
    arguments.addAll(['--source', source.path, '--install-mode', 'source']);
  }
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

  _step('running local ${options.mode} install');
  final result = await Process.run('bash', arguments);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode != 0) {
    throw 'install failed with exit code ${result.exitCode}';
  }

  final match = RegExp(r'\[hampanel\] enrollment: (.+)')
      .firstMatch(result.stderr.toString());
  if (match == null) throw 'could not locate the enrollment bundle path';
  await _storeEnrollment(match.group(1)!.trim(), options.out!);
}

Future<void> _deployLinux(_Options options, Directory source) async {
  if (options.mode == 'binary') {
    await _installLinuxFromRelease(options);
    return;
  }

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
    '$target:/tmp/hampanel-src.tgz',
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
    '--mode',
    'source',
    '--install-mode',
    'source',
    '--endpoint',
    options.endpoint,
  ];
  _appendInstallArgs(bootstrapArgs, options);
  if (options.noStart) bootstrapArgs.add('--no-start');

  final command = <String>[
    if (options.sudo || options.user != 'root') 'sudo',
    ...bootstrapArgs,
  ].join(' ');

  _step('building and installing from source (this may take a few minutes)');
  await _ssh(options, [command]);
  await _fetchEnrollmentLinux(options);
}

Future<void> _installLinuxFromRelease(_Options options) async {
  final url = '${_releaseBase(options)}/hampanel-install-linux.sh';
  final args = <String>[
    '--mode',
    'binary',
    '--channel',
    options.channel,
    '--repo',
    options.repo,
    '--endpoint',
    options.endpoint,
  ];
  _appendInstallArgs(args, options);
  if (options.noStart) args.add('--no-start');

  final runAs = options.sudo || options.user != 'root' ? 'sudo ' : '';
  final command =
      'curl -fsSL ${_quote(url)} | ${runAs}bash -s -- ${args.map(_quote).join(' ')}';

  _step('installing release binary on ${options.host}');
  await _ssh(options, [command]);
  await _fetchEnrollmentLinux(options);
}

void _appendInstallArgs(List<String> args, _Options options) {
  if (options.panelPort != null)
    args.addAll(['--port', '${options.panelPort}']);
  if (options.entryPrefix != null)
    args.addAll(['--entry-prefix', options.entryPrefix!]);
  if (options.prefix != null) args.addAll(['--prefix', options.prefix!]);
  if (options.configDir != null)
    args.addAll(['--config-dir', options.configDir!]);
  if (options.dataDir != null) args.addAll(['--data-dir', options.dataDir!]);
  if (options.tlsDir != null) args.addAll(['--tls-dir', options.tlsDir!]);
  if (options.enrollFile != null)
    args.addAll(['--enroll-file', options.enrollFile!]);
  for (final san in options.sans) {
    args.addAll(['--san', san]);
  }
}

Future<void> _fetchEnrollmentLinux(_Options options) async {
  _step('fetching enrollment bundle');
  final remoteEnroll =
      options.enrollFile ??
      (options.configDir != null
          ? '${options.configDir}/enroll.json'
          : '/etc/hampanel/enroll.json');
  final cat =
      '${options.sudo || options.user != 'root' ? 'sudo ' : ''}cat $remoteEnroll';
  final enrollment = await _ssh(options, [cat], capture: true);
  await _writeEnrollment(enrollment, options.out!);
}

Future<void> _deployWindows(_Options options, Directory source) async {
  if (options.mode == 'binary') {
    await _installWindowsFromRelease(options);
    return;
  }

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
    '$target:C:/ProgramData/hampanel/src.tgz',
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
    '-Mode',
    'source',
  ];
  _appendWindowsArgs(installArgs, options);

  final escaped = installArgs.map(_windowsArg).join(' ');
  _step('building and installing Windows service from source');
  await _ssh(options, [
    'powershell -NoProfile -ExecutionPolicy Bypass -File '
            r'C:\ProgramData\hampanel\src\deploy\windows\install.ps1 ' +
        escaped,
  ]);
  await _fetchEnrollmentWindows(options);
}

Future<void> _installWindowsFromRelease(_Options options) async {
  final url = '${_releaseBase(options)}/hampanel-install-windows.ps1';
  final args = <String>[
    '-Mode',
    'binary',
    '-Channel',
    options.channel,
    '-Repo',
    options.repo,
    '-Endpoint',
    options.endpoint,
  ];
  _appendWindowsArgs(args, options);
  final escaped = args.map(_windowsArg).join(' ');

  _step('installing release binary on ${options.host}');
  await _ssh(options, [
    'powershell -NoProfile -ExecutionPolicy Bypass -Command "'
        "New-Item -ItemType Directory -Force -Path 'C:\\ProgramData\\hampanel' | Out-Null; "
        "Invoke-WebRequest -UseBasicParsing -Uri '${url}' -OutFile 'C:\\ProgramData\\hampanel\\install.ps1'; "
        "& 'C:\\ProgramData\\hampanel\\install.ps1' $escaped\"",
  ]);
  await _fetchEnrollmentWindows(options);
}

void _appendWindowsArgs(List<String> args, _Options options) {
  if (options.panelPort != null) args.addAll(['-Port', '${options.panelPort}']);
  if (options.entryPrefix != null)
    args.addAll(['-EntryPrefix', options.entryPrefix!]);
  if (options.prefix != null) args.addAll(['-InstallDir', options.prefix!]);
  if (options.dataDir != null) args.addAll(['-DataDir', options.dataDir!]);
  for (final san in options.sans) {
    args.addAll(['-San', san]);
  }
  if (options.openSslDir != null)
    args.addAll(['-OpenSslDir', options.openSslDir!]);
  if (options.installDriver) args.add('-InstallDriver');
}

Future<void> _fetchEnrollmentWindows(_Options options) async {
  _step('fetching enrollment bundle');
  final enrollment = await _ssh(options, [
    r'powershell -NoProfile -Command "Get-Content C:\ProgramData\hampanel\enroll.json -Raw"',
  ], capture: true);
  await _writeEnrollment(enrollment, options.out!);
}

String _releaseBase(_Options options) =>
    (options.channel == 'stable' || options.channel == 'latest')
    ? 'https://github.com/${options.repo}/releases/latest/download'
    : 'https://github.com/${options.repo}/releases/download/${options.channel}';

String _quote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String _windowsArg(String value) {
  if (!value.contains(' ') && !value.contains("'")) return value;
  return "'${value.replaceAll("'", "''")}'";
}

Future<String> _ssh(
  _Options options,
  List<String> commands, {
  bool capture = false,
}) async {
  final args = [
    '-p',
    '${options.sshPort}',
    '-o',
    'StrictHostKeyChecking=accept-new',
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
  --mode <binary|source>   install a published release binary (default) or build from source
  --channel <stable|nightly> release channel for binary installs (default: stable)
  --repo <owner/repo>      GitHub repository for releases (default: colisys/hampanel)
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

  # build and install from the local working tree instead of a release
  dart run tool/hampanelctl/bin/hampanelctl.dart deploy --mode source \\
      --host 203.0.113.10 --san 203.0.113.10

  dart run tool/hampanelctl/bin/hampanelctl.dart deploy --local --no-systemd \\
      --endpoint 127.0.0.1:8443 --san 127.0.0.1
''');
}
