import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/ssh_installer.dart';

void main() {
  test('source refs select the matching channel', () {
    expect(
      effectiveInstallChannel(
          mode: 'source', channel: 'stable', sourceRef: 'nightly'),
      'nightly',
    );
    expect(
      effectiveInstallChannel(
          mode: 'source', channel: 'nightly', sourceRef: 'v1.2.3'),
      'stable',
    );
    expect(
      effectiveInstallChannel(
          mode: 'source', channel: 'stable', sourceRef: 'main'),
      'nightly',
    );
    expect(
      effectiveInstallChannel(
          mode: 'binary', channel: 'nightly', sourceRef: 'nightly'),
      'nightly',
    );
  });

  test('installer base follows the effective channel', () {
    final sourceNightly = SshInstallRequest(
      host: 'h',
      username: 'u',
      mode: 'source',
      channel: 'stable',
      sourceRef: 'nightly',
    );
    expect(
      releaseBaseFor(sourceNightly),
      'https://github.com/colisys/hampanel/releases/download/nightly',
    );

    final sourceTag = SshInstallRequest(
      host: 'h',
      username: 'u',
      mode: 'source',
      channel: 'nightly',
      sourceRef: 'v1.2.3',
    );
    expect(
      releaseBaseFor(sourceTag),
      'https://github.com/colisys/hampanel/releases/latest/download',
    );

    final binary = SshInstallRequest(
      host: 'h',
      username: 'u',
      mode: 'binary',
      channel: 'nightly',
    );
    expect(
      releaseBaseFor(binary),
      'https://github.com/colisys/hampanel/releases/download/nightly',
    );
  });

  test('mirror is applied exactly once', () {
    final request = SshInstallRequest(
      host: 'h',
      username: 'u',
      mode: 'source',
      channel: 'stable',
      sourceRef: 'nightly',
      githubMirror: 'https://mirror.example.com/',
    );
    expect(
      releaseBaseFor(request),
      'https://mirror.example.com/https://github.com/colisys/hampanel/releases/download/nightly',
    );
  });
}
