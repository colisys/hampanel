class CpuMetrics {
  const CpuMetrics({
    required this.usagePercent,
    required this.cores,
    required this.load1,
    required this.load5,
    required this.load15,
  });

  final double usagePercent;
  final int cores;
  final double load1;
  final double load5;
  final double load15;

  factory CpuMetrics.fromJson(Map<String, dynamic> json) => CpuMetrics(
    usagePercent: (json['usage_percent'] as num?)?.toDouble() ?? 0,
    cores: (json['cores'] as num?)?.toInt() ?? 0,
    load1: (json['load1'] as num?)?.toDouble() ?? 0,
    load5: (json['load5'] as num?)?.toDouble() ?? 0,
    load15: (json['load15'] as num?)?.toDouble() ?? 0,
  );
}

class MemoryMetrics {
  const MemoryMetrics({
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.percent,
    required this.swapTotalBytes,
    required this.swapUsedBytes,
  });

  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final double percent;
  final int swapTotalBytes;
  final int swapUsedBytes;

  factory MemoryMetrics.fromJson(Map<String, dynamic> json) => MemoryMetrics(
    totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
    usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
    availableBytes: (json['available_bytes'] as num?)?.toInt() ?? 0,
    percent: (json['percent'] as num?)?.toDouble() ?? 0,
    swapTotalBytes: (json['swap_total_bytes'] as num?)?.toInt() ?? 0,
    swapUsedBytes: (json['swap_used_bytes'] as num?)?.toInt() ?? 0,
  );
}

class DiskMetrics {
  const DiskMetrics({
    required this.mount,
    required this.filesystem,
    required this.totalBytes,
    required this.usedBytes,
    required this.availableBytes,
    required this.percent,
  });

  final String mount;
  final String filesystem;
  final int totalBytes;
  final int usedBytes;
  final int availableBytes;
  final double percent;

  factory DiskMetrics.fromJson(Map<String, dynamic> json) => DiskMetrics(
    mount: json['mount'] as String? ?? '-',
    filesystem: json['filesystem'] as String? ?? '-',
    totalBytes: (json['total_bytes'] as num?)?.toInt() ?? 0,
    usedBytes: (json['used_bytes'] as num?)?.toInt() ?? 0,
    availableBytes: (json['available_bytes'] as num?)?.toInt() ?? 0,
    percent: (json['percent'] as num?)?.toDouble() ?? 0,
  );
}

class InterfaceMetrics {
  const InterfaceMetrics({
    required this.name,
    required this.rxBytes,
    required this.txBytes,
    required this.rxRateBps,
    required this.txRateBps,
  });

  final String name;
  final int rxBytes;
  final int txBytes;
  final double rxRateBps;
  final double txRateBps;

  factory InterfaceMetrics.fromJson(Map<String, dynamic> json) =>
      InterfaceMetrics(
        name: json['name'] as String? ?? '-',
        rxBytes: (json['rx_bytes'] as num?)?.toInt() ?? 0,
        txBytes: (json['tx_bytes'] as num?)?.toInt() ?? 0,
        rxRateBps: (json['rx_rate_bps'] as num?)?.toDouble() ?? 0,
        txRateBps: (json['tx_rate_bps'] as num?)?.toDouble() ?? 0,
      );
}

class NetworkMetrics {
  const NetworkMetrics({
    required this.rxBytes,
    required this.txBytes,
    required this.rxRateBps,
    required this.txRateBps,
    required this.interfaces,
  });

  final int rxBytes;
  final int txBytes;
  final double rxRateBps;
  final double txRateBps;
  final List<InterfaceMetrics> interfaces;

  factory NetworkMetrics.fromJson(Map<String, dynamic> json) => NetworkMetrics(
    rxBytes: (json['rx_bytes'] as num?)?.toInt() ?? 0,
    txBytes: (json['tx_bytes'] as num?)?.toInt() ?? 0,
    rxRateBps: (json['rx_rate_bps'] as num?)?.toDouble() ?? 0,
    txRateBps: (json['tx_rate_bps'] as num?)?.toDouble() ?? 0,
    interfaces: ((json['interfaces'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(InterfaceMetrics.fromJson)
        .toList(),
  );
}

class Metrics {
  const Metrics({
    required this.cpu,
    required this.memory,
    required this.uptimeSeconds,
    required this.disks,
    required this.network,
  });

  final CpuMetrics cpu;
  final MemoryMetrics memory;
  final int uptimeSeconds;
  final List<DiskMetrics> disks;
  final NetworkMetrics network;

  factory Metrics.fromJson(Map<String, dynamic> json) => Metrics(
    cpu: CpuMetrics.fromJson(json['cpu'] as Map<String, dynamic>? ?? const {}),
    memory: MemoryMetrics.fromJson(
      json['memory'] as Map<String, dynamic>? ?? const {},
    ),
    uptimeSeconds: (json['uptime_seconds'] as num?)?.toInt() ?? 0,
    disks: ((json['disks'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DiskMetrics.fromJson)
        .toList(),
    network: NetworkMetrics.fromJson(
      json['network'] as Map<String, dynamic>? ?? const {},
    ),
  );
}
