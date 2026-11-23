/// A scheduled job. `panel` jobs run curated daemon commands, `user` jobs are
/// free-form crontab entries, so the UI never mixes the two.
class CronEntry {
  const CronEntry({
    required this.id,
    required this.schedule,
    required this.command,
    required this.line,
    this.kind = 'user',
  });

  final String id;
  final String schedule;
  final String command;
  final String line;
  final String kind;

  bool get isPanel => kind == 'panel';

  factory CronEntry.fromJson(Map<String, dynamic> json) => CronEntry(
    id: json['id'] as String? ?? '',
    schedule: json['schedule'] as String? ?? '',
    command: json['command'] as String? ?? '',
    line: json['line'] as String? ?? '',
    kind: json['kind'] as String? ?? 'user',
  );
}

/// One entry of the curated panel job catalog returned by `/api/v1/cron`.
class CronPanelJob {
  const CronPanelJob({
    required this.id,
    required this.label,
    this.group,
    required this.command,
  });

  final String id;
  final String label;
  final String? group;
  final String command;

  factory CronPanelJob.fromJson(Map<String, dynamic> json) => CronPanelJob(
    id: json['id'] as String? ?? '',
    group: json['group'] as String?,
    label: json['label'] as String? ?? '',
    command: json['command'] as String? ?? '',
  );
}
