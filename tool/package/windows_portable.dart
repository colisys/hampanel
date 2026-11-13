// Package the Flutter Windows client as a single portable executable.
//
// The bundle is compressed into a 7z payload and prepended with an installer
// SFX module (7zSD.sfx). Running the resulting .exe extracts the client to the
// user's temp directory and launches hampanel.exe; user data still lives in
// %APPDATA%\Hampanel.
import 'dart:convert';
import 'dart:io';

const _defaultSfxUrl = 'https://www.7-zip.org/a/lzma2501.7z';
const _defaultSfxName = '7zSD.sfx';

Future<void> main(List<String> args) async {
  final options = _parseArgs(args);
  if (options == null) return;

  final script = File.fromUri(Platform.script).absolute;
  final repoRoot = script.parent.parent.parent;
  final cache = Directory(
    options.cache ??
        '${repoRoot.path}${Platform.pathSeparator}app${Platform.pathSeparator}build${Platform.pathSeparator}packaging${Platform.pathSeparator}cache',
  );

  final bundle = Directory(options.bundle);
  final runProgram = options.runProgram;
  if (!bundle.existsSync()) {
    _fail('bundle directory not found: ${bundle.path}');
  }
  if (!File('${bundle.path}${Platform.pathSeparator}$runProgram')
      .existsSync()) {
    _fail('$runProgram not found in ${bundle.path}');
  }

  final sevenZip = _findSevenZip(options.sevenZip);
  if (sevenZip == null) {
    _fail('7-Zip not found; install it or pass --sevenzip <path>');
  }

  cache.createSync(recursive: true);
  final sfx = await _resolveSfx(options.sfx, cache, sevenZip);

  final work = Directory.systemTemp.createTempSync('hampanel-portable-');
  try {
    final payload = File('${work.path}${Platform.pathSeparator}payload.7z');
    stdout.writeln('compressing ${bundle.path} ...');
    final archive = Process.runSync(
      sevenZip,
      ['a', '-t7z', '-mx=9', '-y', payload.path, '.'],
      workingDirectory: bundle.path,
      runInShell: false,
    );
    if (archive.exitCode != 0) {
      _fail(
        '7z failed (${archive.exitCode}):\n${archive.stdout}\n${archive.stderr}',
      );
    }

    final config = File('${work.path}${Platform.pathSeparator}config.txt');
    config.writeAsStringSync(
      ';!@Install@!UTF-8!\n'
      'Title="${options.title}"\n'
      'RunProgram="$runProgram"\n'
      ';!@InstallEnd@!\n',
      encoding: utf8,
      flush: true,
    );

    final output = File(options.output);
    output.parent.createSync(recursive: true);
    if (output.existsSync()) output.deleteSync();
    final sink = output.openWrite();
    await sink.addStream(sfx.openRead());
    await sink.addStream(config.openRead());
    await sink.addStream(payload.openRead());
    await sink.flush();
    await sink.close();

    final size = output.lengthSync();
    stdout.writeln('${output.path} (${_humanSize(size)})');
  } finally {
    work.deleteSync(recursive: true);
  }
}

Future<File> _resolveSfx(
  String? explicit,
  Directory cache,
  String sevenZip,
) async {
  if (explicit != null) {
    final file = File(explicit);
    if (!file.existsSync()) _fail('SFX module not found: $explicit');
    return file;
  }
  final cached = File('${cache.path}${Platform.pathSeparator}$_defaultSfxName');
  if (cached.existsSync()) return cached;

  final download = File('${cache.path}${Platform.pathSeparator}lzma-sdk.7z');
  stdout.writeln('downloading $_defaultSfxUrl ...');
  await _download(_defaultSfxUrl, download);

  final extractDir = Directory.systemTemp.createTempSync('hampanel-sfx-');
  try {
    final result = Process.runSync(sevenZip, [
      'e',
      '-y',
      '-o${extractDir.path}',
      download.path,
      'bin/$_defaultSfxName',
    ]);
    if (result.exitCode != 0) {
      _fail(
        'failed to extract $_defaultSfxName:\n${result.stdout}\n${result.stderr}',
      );
    }
    final extracted = File(
      '${extractDir.path}${Platform.pathSeparator}$_defaultSfxName',
    );
    if (!extracted.existsSync())
      _fail('$_defaultSfxName missing from LZMA SDK');
    extracted.copySync(cached.path);
  } finally {
    extractDir.deleteSync(recursive: true);
    if (download.existsSync()) download.deleteSync();
  }
  return cached;
}

Future<void> _download(String url, File destination) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse(url));
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      _fail('download failed: HTTP ${response.statusCode} for $url');
    }
    final sink = destination.openWrite();
    await response.pipe(sink);
  } finally {
    client.close();
  }
}

String? _findSevenZip(String? explicit) {
  if (explicit != null) {
    return File(explicit).existsSync() ? explicit : null;
  }
  final fromEnv = Platform.environment['SEVENZIP'];
  if (fromEnv != null && File(fromEnv).existsSync()) return fromEnv;

  if (Platform.isWindows) {
    for (final root in [
      Platform.environment['ProgramFiles'],
      Platform.environment['ProgramFiles(x86)'],
    ]) {
      if (root == null) continue;
      final candidate = File('$root\\7-Zip\\7z.exe');
      if (candidate.existsSync()) return candidate.path;
    }
  }
  for (final name in ['7z', '7za']) {
    final finder = Platform.isWindows ? 'where' : 'which';
    final result = Process.runSync(finder, [name], runInShell: false);
    if (result.exitCode == 0) {
      final line = const LineSplitter()
          .convert(result.stdout.toString())
          .firstWhere((value) => value.trim().isNotEmpty, orElse: () => '');
      if (line.trim().isNotEmpty) return line.trim();
    }
  }
  return null;
}

class _Options {
  _Options({
    required this.bundle,
    required this.output,
    required this.title,
    required this.runProgram,
    required this.cache,
    required this.sevenZip,
    required this.sfx,
  });

  final String bundle;
  final String output;
  final String title;
  final String runProgram;
  final String? cache;
  final String? sevenZip;
  final String? sfx;
}

_Options? _parseArgs(List<String> args) {
  String? bundle;
  String? output;
  var title = 'Hampanel';
  var runProgram = 'hampanel.exe';
  String? cache;
  String? sevenZip;
  String? sfx;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String next() {
      if (i + 1 >= args.length) _fail('missing value for $arg');
      return args[++i];
    }

    switch (arg) {
      case '--bundle':
        bundle = next();
      case '--output':
        output = next();
      case '--title':
        title = next();
      case '--run-program':
        runProgram = next();
      case '--cache':
        cache = next();
      case '--sevenzip':
        sevenZip = next();
      case '--sfx':
        sfx = next();
      case '-h':
      case '--help':
        _usage();
        return null;
      default:
        _fail('unknown argument: $arg');
    }
  }

  if (bundle == null || output == null) {
    _usage();
    _fail('--bundle and --output are required');
  }
  return _Options(
    bundle: bundle,
    output: output,
    title: title,
    runProgram: runProgram,
    cache: cache,
    sevenZip: sevenZip,
    sfx: sfx,
  );
}

void _usage() {
  stdout.writeln('''
Usage: dart tool/package/windows_portable.dart --bundle <dir> --output <file.exe> [options]

  --bundle <dir>       Flutter Windows Release directory
  --output <file>      Output single-file .exe
  --title <text>       SFX dialog title (default: Hampanel)
  --run-program <exe>  Executable inside the bundle (default: hampanel.exe)
  --cache <dir>        SFX module cache directory
  --sevenzip <path>    7z executable
  --sfx <path>         Existing 7zS2.sfx module
''');
}

String _humanSize(int bytes) {
  const units = ['B', 'KiB', 'MiB', 'GiB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(1)} ${units[unit]}';
}

Never _fail(String message) {
  stderr.writeln('error: $message');
  exit(1);
}
