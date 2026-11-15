class SshLoggingStatus {
  const SshLoggingStatus({
    required this.mode,
    required this.file,
    required this.rsyslogAvailable,
    required this.rsyslogService,
    required this.journalAvailable,
    required this.authLogPath,
    required this.service,
    required this.message,
  });

  final String mode;
  final String file;
  final bool rsyslogAvailable;
  final String rsyslogService;
  final bool journalAvailable;
  final String authLogPath;
  final String service;
  final String message;

  factory SshLoggingStatus.fromJson(Map<String, dynamic> json) =>
      SshLoggingStatus(
        mode: json['mode'] as String? ?? 'syslog',
        file: json['file'] as String? ?? '',
        rsyslogAvailable: json['rsyslog_available'] as bool? ?? false,
        rsyslogService: json['rsyslog_service'] as String? ?? '',
        journalAvailable: json['journal_available'] as bool? ?? false,
        authLogPath: json['auth_log_path'] as String? ?? '',
        service: json['service'] as String? ?? '',
        message: json['message'] as String? ?? '',
      );
}

class SshLogs {
  const SshLogs({
    required this.source,
    required this.path,
    required this.truncated,
    required this.content,
  });

  final String source;
  final String path;
  final bool truncated;
  final String content;

  factory SshLogs.fromJson(Map<String, dynamic> json) => SshLogs(
    source: json['source'] as String? ?? '',
    path: json['path'] as String? ?? '',
    truncated: json['truncated'] as bool? ?? false,
    content: json['content'] as String? ?? '',
  );
}
