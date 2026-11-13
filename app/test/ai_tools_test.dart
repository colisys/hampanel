import 'package:flutter_test/flutter_test.dart';
import 'package:hampanel/features/ai/ai_tools.dart';

void main() {
  test('AI defaults disable cron and keep read-only tools', () {
    final tools = buildAiTools();
    final defaults = AiToolPreferences.defaultsFor(tools);
    expect(defaults.contains('add_cron_job'), isFalse);
    expect(defaults.contains('get_system_info'), isTrue);
    expect(defaults.contains('delete_path'), isTrue);
  });

  test('sensitive path prefixes match directories and children', () {
    final previous = AiToolPreferences.sensitivePaths.value;
    AiToolPreferences.sensitivePaths.value = ['/etc/ssh', '/root/.ssh'];
    expect(AiToolPreferences.isSensitivePath('/etc/ssh'), isTrue);
    expect(AiToolPreferences.isSensitivePath('/etc/ssh/sshd_config'), isTrue);
    expect(AiToolPreferences.isSensitivePath('/etc/passwd'), isFalse);
    AiToolPreferences.sensitivePaths.value = previous;
  });
}
