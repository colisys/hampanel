import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/docker/podman_settings_panel.dart';

void main() {
  test('writes containers/storage string booleans and drops legacy keys', () {
    const source = '''
[storage]
driver = "overlay"
graphroot = "/var/lib/containers/storage"
transient_store = false
mountopt = "nodev"
mount_program = "/usr/bin/fuse-overlayfs"
volume_path = "/var/lib/containers/storage/volumes"

[storage.options.overlay]
ignore_chown_errors = true
inodes = 12345
''';
    final output = patchPodmanStorageToml(
      source,
      driver: 'overlay',
      graphroot: '/var/lib/containers/storage',
      runroot: '/run/containers/storage',
      rootlessStoragePath: '',
      mountProgram: '',
      overlayMountProgram: '/usr/bin/fuse-overlayfs',
      mountOpt: 'nodev',
      overlaySize: '10g',
      overlayInodes: '12345',
      ignoreChownErrors: true,
    );

    expect(output, contains('ignore_chown_errors = "true"'));
    expect(output, isNot(contains('ignore_chown_errors = true')));
    expect(output, contains('inodes = "12345"'));
    expect(output, isNot(contains('inodes = 12345')));
    expect(output, isNot(contains('transient_store')));
    expect(output, contains('mountopt = "nodev"'));
    expect(output, contains('mount_program = "/usr/bin/fuse-overlayfs"'));

    final storageSection = output.split('[storage.options')[0];
    expect(storageSection, isNot(contains('mountopt')));
    expect(storageSection, isNot(contains('mount_program')));
    expect(storageSection, isNot(contains('volume_path')));
  });

  test('replace an existing boolean chown value exactly once', () {
    const source = '''
[storage]
driver = "overlay"

[storage.options.overlay]
ignore_chown_errors = false
''';
    final output = patchPodmanStorageToml(
      source,
      driver: 'overlay',
      graphroot: '/var/lib/containers/storage',
      runroot: '/run/containers/storage',
      rootlessStoragePath: '',
      mountProgram: '',
      overlayMountProgram: '',
      mountOpt: '',
      overlaySize: '',
      overlayInodes: '',
      ignoreChownErrors: false,
    );
    expect(RegExp(r'ignore_chown_errors\s*=').allMatches(output).length, 1);
    expect(output, contains('ignore_chown_errors = "false"'));
  });
}
