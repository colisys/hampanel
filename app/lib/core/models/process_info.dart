class ProcessInfo {
  const ProcessInfo({
    required this.pid,
    required this.ppid,
    required this.name,
    required this.state,
    required this.rssBytes,
    required this.cpuTicks,
    required this.command,
  });

  final int pid;
  final int ppid;
  final String name;
  final String state;
  final int rssBytes;
  final int cpuTicks;
  final String command;

  factory ProcessInfo.fromJson(Map<String, dynamic> json) => ProcessInfo(
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    ppid: (json['ppid'] as num?)?.toInt() ?? 0,
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

class ProcessPort {
  const ProcessPort({
    required this.protocol,
    required this.localPort,
    required this.state,
  });

  final String protocol;
  final int localPort;
  final String state;

  factory ProcessPort.fromJson(Map<String, dynamic> json) => ProcessPort(
    protocol: json['protocol'] as String? ?? '-',
    localPort: (json['local_port'] as num?)?.toInt() ?? 0,
    state: json['state'] as String? ?? '-',
  );
}

class ProcessDetail {
  const ProcessDetail({
    required this.pid,
    required this.ppid,
    required this.name,
    required this.state,
    required this.command,
    required this.exe,
    required this.cwd,
    required this.uid,
    required this.gid,
    required this.threads,
    required this.rssBytes,
    required this.cpuTicks,
    required this.openFiles,
    required this.ports,
  });

  final int pid;
  final int ppid;
  final String name;
  final String state;
  final String command;
  final String exe;
  final String cwd;
  final int uid;
  final int gid;
  final int threads;
  final int rssBytes;
  final int cpuTicks;
  final List<String> openFiles;
  final List<ProcessPort> ports;

  factory ProcessDetail.fromJson(Map<String, dynamic> json) => ProcessDetail(
    pid: (json['pid'] as num?)?.toInt() ?? 0,
    ppid: (json['ppid'] as num?)?.toInt() ?? 0,
    name: json['name'] as String? ?? '-',
    state: json['state'] as String? ?? '-',
    command: json['command'] as String? ?? '',
    exe: json['exe'] as String? ?? '',
    cwd: json['cwd'] as String? ?? '',
    uid: (json['uid'] as num?)?.toInt() ?? 0,
    gid: (json['gid'] as num?)?.toInt() ?? 0,
    threads: (json['threads'] as num?)?.toInt() ?? 0,
    rssBytes: (json['rss_bytes'] as num?)?.toInt() ?? 0,
    cpuTicks: (json['cpu_ticks'] as num?)?.toInt() ?? 0,
    openFiles: ((json['open_files'] as List<dynamic>?) ?? const [])
        .whereType<String>()
        .toList(),
    ports: ((json['ports'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(ProcessPort.fromJson)
        .toList(),
  );
}
