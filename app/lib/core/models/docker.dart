class DockerPort {
  const DockerPort({
    required this.hostIp,
    required this.hostPort,
    required this.containerPort,
    required this.protocol,
  });

  final String hostIp;
  final String hostPort;
  final String containerPort;
  final String protocol;

  String get label {
    final proto = protocol.isEmpty ? '' : '/$protocol';
    if (hostPort.isEmpty) return '$containerPort$proto';
    final host = hostIp.isEmpty ? hostPort : '$hostIp:$hostPort';
    return '$host:$containerPort$proto';
  }

  factory DockerPort.fromJson(Map<String, dynamic> json) => DockerPort(
    hostIp: json['host_ip'] as String? ?? '',
    hostPort: json['host_port'] as String? ?? '',
    containerPort: json['container_port'] as String? ?? '',
    protocol: json['protocol'] as String? ?? '',
  );
}

class DockerNetworkInfo {
  const DockerNetworkInfo({required this.name, required this.ip});

  final String name;
  final String ip;

  String get label => ip.isEmpty ? name : '$name · $ip';

  factory DockerNetworkInfo.fromJson(Map<String, dynamic> json) =>
      DockerNetworkInfo(
        name: json['name'] as String? ?? '',
        ip: json['ip'] as String? ?? '',
      );
}

class DockerStats {
  const DockerStats({
    required this.cpuPercent,
    required this.memPercent,
    required this.memUsage,
    required this.netIo,
    required this.blockIo,
    required this.pids,
  });

  final String cpuPercent;
  final String memPercent;
  final String memUsage;
  final String netIo;
  final String blockIo;
  final String pids;

  factory DockerStats.fromJson(Map<String, dynamic> json) => DockerStats(
    cpuPercent: json['cpu_percent'] as String? ?? '',
    memPercent: json['mem_percent'] as String? ?? '',
    memUsage: json['mem_usage'] as String? ?? '',
    netIo: json['net_io'] as String? ?? '',
    blockIo: json['block_io'] as String? ?? '',
    pids: json['pids'] as String? ?? '',
  );
}

class DockerContainer {
  const DockerContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.state,
    required this.status,
    required this.ports,
    required this.createdAt,
    this.imageId = '',
    this.startedAt = '',
    this.note = '',
    this.composeProject = '',
    this.networks = const [],
    this.portMap = const [],
    this.stats,
  });

  final String id;
  final String name;
  final String image;
  final String state;
  final String status;
  final String ports;
  final String createdAt;
  final String imageId;
  final String startedAt;
  final String note;
  final String composeProject;
  final List<DockerNetworkInfo> networks;
  final List<DockerPort> portMap;
  final DockerStats? stats;

  String get shortId => id.length > 12 ? id.substring(0, 12) : id;

  bool get running => state == 'running';

  String get networkLabel => networks.isEmpty
      ? '—'
      : networks.map((entry) => entry.label).join(', ');

  String get portsLabel => portMap.isEmpty
      ? (ports.isEmpty ? '—' : ports)
      : portMap.map((entry) => entry.label).join(', ');

  String get resourceLabel {
    final value = stats;
    if (value == null) return '—';
    final cpu = value.cpuPercent.isEmpty ? '—' : value.cpuPercent;
    final mem = value.memPercent.isEmpty ? '—' : value.memPercent;
    return 'CPU $cpu · 内存 $mem';
  }

  String get uptimeLabel {
    if (!running) return '—';
    final started = DateTime.tryParse(startedAt);
    if (started == null) return status;
    final duration = DateTime.now().difference(started);
    if (duration.isNegative) return status;
    if (duration.inDays > 0) {
      return '${duration.inDays}天 ${duration.inHours % 24}小时';
    }
    if (duration.inHours > 0) {
      return '${duration.inHours}小时 ${duration.inMinutes % 60}分';
    }
    return '${duration.inMinutes}分钟';
  }

  String get createdLabel => formatTimestamp(createdAt);

  factory DockerContainer.fromJson(Map<String, dynamic> json) => DockerContainer(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
    image: json['image'] as String? ?? '',
    state: json['state'] as String? ?? '',
    status: json['status'] as String? ?? '',
    ports: json['ports'] as String? ?? '',
    createdAt: json['created_at'] as String? ?? '',
    imageId: json['image_id'] as String? ?? '',
    startedAt: json['started_at'] as String? ?? '',
    note: json['note'] as String? ?? '',
    composeProject: json['compose_project'] as String? ?? '',
    networks: ((json['networks'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DockerNetworkInfo.fromJson)
        .toList(),
    portMap: ((json['port_map'] as List<dynamic>?) ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(DockerPort.fromJson)
        .toList(),
    stats: json['stats'] is Map<String, dynamic>
        ? DockerStats.fromJson(json['stats'] as Map<String, dynamic>)
        : null,
  );
}

class DockerMount {
  const DockerMount({
    required this.type,
    required this.source,
    required this.destination,
    required this.readOnly,
    required this.name,
  });

  final String type;
  final String source;
  final String destination;
  final bool readOnly;
  final String name;

  String get spec {
    if (type == 'volume' && name.isNotEmpty) {
      return readOnly ? '$name:$destination:ro' : '$name:$destination';
    }
    return readOnly ? '$source:$destination:ro' : '$source:$destination';
  }

  factory DockerMount.fromJson(Map<String, dynamic> json) => DockerMount(
    type: json['type'] as String? ?? '',
    source: json['source'] as String? ?? '',
    destination: json['destination'] as String? ?? '',
    readOnly: json['read_only'] as bool? ?? false,
    name: json['name'] as String? ?? '',
  );
}

class DockerContainerDetail {
  const DockerContainerDetail({
    required this.id,
    required this.name,
    required this.image,
    required this.imageId,
    required this.state,
    required this.status,
    required this.createdAt,
    required this.startedAt,
    required this.restartPolicy,
    required this.restartMax,
    required this.env,
    required this.ports,
    required this.mounts,
    required this.networks,
    required this.networkMode,
    required this.labels,
    required this.composeProject,
    required this.note,
    required this.command,
    required this.entrypoint,
    this.cpus,
    this.memory,
  });

  final String id;
  final String name;
  final String image;
  final String imageId;
  final String state;
  final String status;
  final String createdAt;
  final String startedAt;
  final String restartPolicy;
  final int restartMax;
  final List<String> env;
  final List<DockerPort> ports;
  final List<DockerMount> mounts;
  final List<DockerNetworkInfo> networks;
  final String networkMode;
  final List<String> labels;
  final String composeProject;
  final String note;
  final List<String> command;
  final List<String> entrypoint;
  final double? cpus;
  final int? memory;

  factory DockerContainerDetail.fromJson(Map<String, dynamic> json) =>
      DockerContainerDetail(
        id: json['id'] as String? ?? '',
        name: json['name'] as String? ?? '',
        image: json['image'] as String? ?? '',
        imageId: json['image_id'] as String? ?? '',
        state: json['state'] as String? ?? '',
        status: json['status'] as String? ?? '',
        createdAt: json['created_at'] as String? ?? '',
        startedAt: json['started_at'] as String? ?? '',
        restartPolicy: json['restart_policy'] as String? ?? 'no',
        restartMax: (json['restart_max'] as num?)?.toInt() ?? 0,
        env: ((json['env'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        ports: ((json['ports'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerPort.fromJson)
            .toList(),
        mounts: ((json['mounts'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerMount.fromJson)
            .toList(),
        networks: ((json['networks'] as List<dynamic>?) ?? const [])
            .whereType<Map<String, dynamic>>()
            .map(DockerNetworkInfo.fromJson)
            .toList(),
        networkMode: json['network_mode'] as String? ?? '',
        labels: ((json['labels'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        composeProject: json['compose_project'] as String? ?? '',
        note: json['note'] as String? ?? '',
        command: ((json['command'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        entrypoint: ((json['entrypoint'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        cpus: (json['cpus'] as num?)?.toDouble(),
        memory: (json['memory'] as num?)?.toInt(),
      );
}

class DockerOverview {
  const DockerOverview({
    required this.available,
    required this.engine,
    required this.running,
    required this.stopped,
    required this.restarting,
    required this.failed,
    required this.compose,
    required this.images,
    required this.networks,
    required this.volumes,
  });

  final bool available;
  final String engine;
  final int running;
  final int stopped;
  final int restarting;
  final int failed;
  final int compose;
  final int images;
  final int networks;
  final int volumes;

  factory DockerOverview.fromJson(Map<String, dynamic> json) {
    final containers =
        json['containers'] as Map<String, dynamic>? ?? const {};
    return DockerOverview(
      available: json['available'] as bool? ?? false,
      engine: json['engine'] as String? ?? '',
      running: (containers['running'] as num?)?.toInt() ?? 0,
      stopped: (containers['stopped'] as num?)?.toInt() ?? 0,
      restarting: (containers['restarting'] as num?)?.toInt() ?? 0,
      failed: (containers['failed'] as num?)?.toInt() ?? 0,
      compose: (json['compose'] as num?)?.toInt() ?? 0,
      images: (json['images'] as num?)?.toInt() ?? 0,
      networks: (json['networks'] as num?)?.toInt() ?? 0,
      volumes: (json['volumes'] as num?)?.toInt() ?? 0,
    );
  }
}

String formatTimestamp(String raw) {
  final value = DateTime.tryParse(raw);
  if (value == null) return raw;
  final local = value.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class DockerComposeProject {
  const DockerComposeProject({
    required this.name,
    required this.managed,
    required this.adopted,
    required this.status,
    required this.dir,
    required this.sourceDir,
    required this.files,
    required this.configFiles,
  });

  final String name;
  final bool managed;
  final bool adopted;
  final String status;
  final String dir;
  final String sourceDir;
  final List<String> files;
  final List<String> configFiles;

  factory DockerComposeProject.fromJson(Map<String, dynamic> json) =>
      DockerComposeProject(
        name: json['name'] as String? ?? '',
        managed: json['managed'] as bool? ?? false,
        adopted: json['adopted'] as bool? ?? false,
        status: json['status'] as String? ?? '',
        dir: json['dir'] as String? ?? '',
        sourceDir: json['source_dir'] as String? ?? '',
        files: ((json['files'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
        configFiles: ((json['config_files'] as List<dynamic>?) ?? const [])
            .whereType<String>()
            .toList(),
      );
}

class DockerComposeDetail {
  const DockerComposeDetail({
    required this.project,
    required this.content,
  });

  final DockerComposeProject project;
  final String content;

  factory DockerComposeDetail.fromJson(Map<String, dynamic> json) =>
      DockerComposeDetail(
        project: DockerComposeProject.fromJson(json),
        content: json['content'] as String? ?? '',
      );
}

class DockerJob {
  const DockerJob({
    required this.id,
    required this.status,
    required this.output,
    required this.truncated,
    required this.exitCode,
  });

  final String id;
  final String status;
  final String output;
  final bool truncated;
  final int? exitCode;

  bool get running => status == 'running';

  factory DockerJob.fromJson(Map<String, dynamic> json) => DockerJob(
    id: json['id'] as String? ?? '',
    status: json['status'] as String? ?? '',
    output: json['output'] as String? ?? '',
    truncated: json['truncated'] as bool? ?? false,
    exitCode: (json['exit_code'] as num?)?.toInt(),
  );
}
