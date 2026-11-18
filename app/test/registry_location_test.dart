import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/docker/podman_settings_panel.dart';

void main() {
  test('registry locations drop schemes and trailing slashes', () {
    expect(
      normalizeRegistryLocation('https://docker.example.com/'),
      'docker.example.com',
    );
    expect(
      normalizeRegistryLocation('http://registry.internal:5000/v2/'),
      'registry.internal:5000/v2',
    );
    expect(
      normalizeRegistryLocation('  mirror.example.com  '),
      'mirror.example.com',
    );
    expect(normalizeRegistryLocation(''), '');
  });
}
