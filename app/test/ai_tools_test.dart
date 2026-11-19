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

  test('log tools are high risk, off by default and review-first', () {
    final tools = buildAiTools();
    final defaults = AiToolPreferences.defaultsFor(tools);
    for (final name in const [
      'list_log_sources',
      'read_logs',
      'read_service_logs',
      'read_container_logs',
    ]) {
      final tool = tools.firstWhere((candidate) => candidate.name == name);
      expect(tool.highRisk, isTrue, reason: name);
      expect(tool.defaultEnabled, isFalse, reason: name);
      expect(defaults.contains(name), isFalse, reason: name);
    }
    for (final name in const [
      'read_logs',
      'read_service_logs',
      'read_container_logs',
    ]) {
      final tool = tools.firstWhere((candidate) => candidate.name == name);
      expect(tool.review, isNotNull, reason: '$name must be reviewed');
      expect(tool.requiresApproval, isNull, reason: '$name uses review');
    }
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
