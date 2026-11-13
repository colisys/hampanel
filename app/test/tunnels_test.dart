import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/core/models/tunnel_profile.dart';
import 'package:hampanel/features/tunnels/tunnel_runner.dart';

TunnelProfile _profile({String mode = 'local', String jump = ''}) => TunnelProfile(
      id: 'test',
      name: 'test',
      mode: mode,
      sshHost: 'example.com',
      sshPort: 22,
      sshUser: 'root',
      keyPath: '',
      jumpHost: jump,
      localPort: 1080,
      remotePort: 8080,
      targetHost: '127.0.0.1',
      targetPort: 80,
      createdAt: 1,
    );

void main() {
  test('local and reverse tunnels accept a single jump host', () {
    expect(() => TunnelRunner.validate(_profile(jump: 'ops@bastion.example.com:2222')),
        returnsNormally);
    expect(() => TunnelRunner.validate(_profile(mode: 'remote')),
        returnsNormally);
  });

  test('jump host rejects multi-hop and shell separators', () {
    expect(() => TunnelRunner.validate(_profile(jump: 'a@b,c@d')), throwsArgumentError);
    expect(() => TunnelRunner.validate(_profile(jump: 'host;rm -rf /')),
        throwsArgumentError);
  });

  test('SOCKS needs no target host', () {
    final profile = _profile(mode: 'socks');
    profile.targetHost = '';
    profile.targetPort = 0;
    expect(() => TunnelRunner.validate(profile), returnsNormally);
  });

  test('profile JSON keeps the jump host', () {
    final decoded = TunnelProfile.fromJson(_profile(jump: 'ops@bastion:22').toJson());
    expect(decoded.jumpHost, 'ops@bastion:22');
  });
}
