import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/client_update.dart';

void main() {
  test('compares semantic versions', () {
    expect(ClientUpdateService.compareVersions('0.1.0', '0.1.0'), 0);
    expect(ClientUpdateService.compareVersions('0.1.1', '0.1.0'), 1);
    expect(ClientUpdateService.compareVersions('0.1.10', '0.1.9'), 1);
    expect(ClientUpdateService.compareVersions('1.0', '0.9.9'), 1);
    expect(ClientUpdateService.compareVersions('0.1.0', '0.2'), -1);
  });

  test('nightly updates by commit, stable only by version', () {
    expect(
      ClientUpdateService.isNewer(
        channel: ClientUpdateChannel.stable,
        remoteVersion: '0.1.0+bbbb',
        localVersion: '0.1.0',
        localCommit: 'aaaa',
      ),
      isFalse,
    );
    expect(
      ClientUpdateService.isNewer(
        channel: ClientUpdateChannel.nightly,
        remoteVersion: '0.1.0+bbbb',
        localVersion: '0.1.0',
        localCommit: 'aaaa',
      ),
      isTrue,
    );
    expect(
      ClientUpdateService.isNewer(
        channel: ClientUpdateChannel.nightly,
        remoteVersion: '0.1.0+aaaa',
        localVersion: '0.1.0',
        localCommit: 'aaaa',
      ),
      isFalse,
    );
    expect(
      ClientUpdateService.isNewer(
        channel: ClientUpdateChannel.nightly,
        remoteVersion: '0.1.1+aaaa',
        localVersion: '0.1.0',
        localCommit: 'aaaa',
      ),
      isTrue,
    );
  });

  test('mirror prefixes upstream urls exactly once', () {
    const url =
        'https://github.com/colisys/hampanel/releases/download/nightly/version.txt';
    expect(
      ClientUpdateService.withMirror(url, 'https://mirror.example/'),
      'https://mirror.example/$url',
    );
    final once = ClientUpdateService.withMirror(url, 'https://mirror.example');
    expect(
      ClientUpdateService.withMirror(once, 'https://mirror.example'),
      once,
    );
    expect(ClientUpdateService.withMirror(url, '  '), url);
  });

  test('picks the client asset per platform', () {
    const release = ClientRelease(
      tag: 'nightly',
      version: '0.1.0+abc',
      notes: '',
      publishedAt: null,
      prerelease: true,
      assets: [
        {
          'name': 'hampanel-client-linux-x86_64.AppImage',
          'browser_download_url': 'https://example/linux',
        },
        {
          'name': 'hampanel-0.1.0-android-universal.apk',
          'browser_download_url': 'https://example/apk',
        },
        {
          'name': 'hampanel-client-macos-arm64.dmg',
          'browser_download_url': 'https://example/macos',
        },
        {
          'name': 'hampanel-0.1.0-ios-unsigned.ipa',
          'browser_download_url': 'https://example/ios',
        },
      ],
    );
    expect(
      ClientUpdateService.clientAsset(
        release,
        operatingSystem: 'linux',
        architecture: 'x86_64',
      ),
      'https://example/linux',
    );
    expect(
      ClientUpdateService.clientAsset(
        release,
        operatingSystem: 'android',
        architecture: 'aarch64',
      ),
      'https://example/apk',
    );
    expect(
      ClientUpdateService.clientAsset(
        release,
        operatingSystem: 'macos',
        architecture: 'arm64',
      ),
      'https://example/macos',
    );
    expect(
      ClientUpdateService.clientAsset(
        release,
        operatingSystem: 'ios',
        architecture: 'arm64',
      ),
      'https://example/ios',
    );
    expect(
      ClientUpdateService.clientAsset(
        release,
        operatingSystem: 'windows',
        architecture: 'x86_64',
      ),
      isNull,
    );
  });
}
