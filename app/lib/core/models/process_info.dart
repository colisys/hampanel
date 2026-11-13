class ProcessInfo {
  const ProcessInfo({
    required this.pid,
    required this.name,
    required this.state,
    required this.rssBytes,
    required this.cpuTicks,
    required this.command,
  });

  final int pid;
  final String name;
  final String state;
  final int rssBytes;
  final int cpuTicks;
  final String command;

  factory ProcessInfo.fromJson(Map<String, dynamic> json) => ProcessInfo(
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '-',
    state: json['state'] as String? ?? '-',
    rssBytes: (json['rss_bytes'] as num?)?.toInt() ?? 0,
    cpuTicks: (json['cpu_ticks'] as num?)?.toInt() ?? 0,
    command: json['command'] as String? ?? '',
  );
}

class ProcessList {
  const ProcessList({required this.total, required this.processes});

  final int total;
  final List<ProcessInfo> processes;

  factory ProcessList.fromJson(Map<String, dynamic> json) => ProcessList(
    total: (json['total'] as num?)?.toInt() ?? 0,
    processes: ((json['processes'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ProcessInfo.fromJson)
        .toList(),
  );
}
