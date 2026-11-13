class CronEntry {
  const CronEntry({
    required this.id,
    required this.schedule,
    required this.command,
    required this.line,
  });

  final String id;
  final String schedule;
  final String command;
  final String line;

  factory CronEntry.fromJson(Map<String, dynamic> json) => CronEntry(
    id: json['id'] as String? ?? '',
    schedule: json['schedule'] as String? ?? '',
    command: json['command'] as String? ?? '',
    line: json['line'] as String? ?? '',
  );
}
