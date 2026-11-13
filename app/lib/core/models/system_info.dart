class SystemInfo {
  const SystemInfo({
    required this.hostname,
    required this.os,
    required this.kernel,
    required this.arch,
    required this.cpuModel,
    required this.cores,
    required this.uptimeSeconds,
    required this.serverTime,
    required this.panelVersion,
    required this.platform,
  });

  final String hostname;
  final String os;
  final String kernel;
  final String arch;
  final String cpuModel;
  final int cores;
  final int uptimeSeconds;
  final String serverTime;
  final String panelVersion;
  final String platform;

  factory SystemInfo.fromJson(Map<String, dynamic> json) => SystemInfo(
    hostname: json['hostname'] as String? ?? '-',
    os: json['os'] as String? ?? '-',
    kernel: json['kernel'] as String? ?? '-',
    arch: json['arch'] as String? ?? '-',
    cpuModel: json['cpu_model'] as String? ?? '-',
    cores: (json['cores'] as num?)?.toInt() ?? 0,
    uptimeSeconds: (json['uptime_seconds'] as num?)?.toInt() ?? 0,
    serverTime: json['server_time'] as String? ?? '-',
    panelVersion: json['panel_version'] as String? ?? '-',
    platform: json['platform'] as String? ?? '-',
  );
}
