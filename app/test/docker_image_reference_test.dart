import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/models/docker.dart';

void main() {
  test('rejects dangling colons without rejecting ports or digests', () {
    for (final reference in ['nginx:', 'registry:5000/team/app:', 'app@sha256: ']) {
      expect(isDockerImageReference(reference), isFalse, reason: reference);
    }
    for (final reference in [
      'registry:5000/team/app',
      'registry:5000/team/app:v1',
      'registry:5000/team/app@sha256:abc',
    ]) {
      expect(isDockerImageReference(reference), isTrue, reason: reference);
    }
  });

  test('image actions preserve the port and digest when applicable', () {
    final image = DockerImage.fromJson({
      'repository': 'registry:5000/team/app@sha256:abc',
      'tag': '<none>',
    });
    expect(image.reference, 'registry:5000/team/app@sha256:abc');
    expect(image.tagTarget, 'registry:5000/team/app');
  });
}
