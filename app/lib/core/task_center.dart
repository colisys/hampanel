import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:material_ui/material_ui.dart';

import 'api_client.dart';

class TaskSummary {
  const TaskSummary({
    required this.id,
    required this.kind,
    required this.title,
    required this.status,
    required this.phase,
    required this.ownerCn,
    this.progress,
    this.createdAt,
    this.startedAt,
    this.finishedAt,
    this.updatedAt,
  });

  final String id;
  final String kind;
  final String title;
  final String status;
  final String phase;
  final String ownerCn;
  final int? progress;
  final DateTime? createdAt;
  final DateTime? startedAt;
  final DateTime? finishedAt;
  final DateTime? updatedAt;

  bool get active =>
      status == 'queued' || status == 'running' || status == 'canceling';

  String get statusLabel => switch (status) {
    'queued' => '排队中',
    'running' => '运行中',
    'canceling' => '取消中',
    'succeeded' => '已完成',
    'failed' => '失败',
    'canceled' => '已取消',
    'interrupted' => '已中断',
    _ => status,
  };

  factory TaskSummary.fromJson(Map<String, dynamic> json) {
    DateTime? time(String key) {
      final value = json[key];
      if (value is int) return DateTime.fromMillisecondsSinceEpoch(value);
      return null;
    }

    return TaskSummary(
      id: json['id'] as String? ?? '',
      kind: json['kind'] as String? ?? '',
      title: json['title'] as String? ?? '',
      status: json['status'] as String? ?? 'queued',
      phase: json['phase'] as String? ?? '',
      ownerCn: json['owner_cn'] as String? ?? '',
      progress: json['progress'] as int?,
      createdAt: time('created_at'),
      startedAt: time('started_at'),
      finishedAt: time('finished_at'),
      updatedAt: time('updated_at'),
    );
  }
}

class TaskCenter extends ChangeNotifier {
  TaskCenter(this.api);

  final ApiClient api;
  final Map<String, TaskSummary> _tasks = {};
  final Random _random = Random.secure();
  bool online = false;
  String? error;
  bool _disposed = false;
  bool _stopped = true;
  bool _running = false;
  Timer? _retryTimer;
  Completer<void>? _retryCompleter;

  List<TaskSummary> get tasks {
    final items = _tasks.values.toList()
      ..sort((a, b) {
        if (a.active != b.active) return a.active ? -1 : 1;
        return (b.updatedAt ?? DateTime(0)).compareTo(
          a.updatedAt ?? DateTime(0),
        );
      });
    return items;
  }

  int get activeCount => _tasks.values.where((task) => task.active).length;

  void start() {
    if (_disposed) return;
    _stopped = false;
    if (!_running) _connect();
  }

  void stop() {
    _stopped = true;
    _retryTimer?.cancel();
    final completer = _retryCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }


  Future<void> _waitBackoff(int seconds) {
    final completer = Completer<void>();
    _retryCompleter = completer;
    _retryTimer = Timer(Duration(seconds: seconds), () {
      if (!completer.isCompleted) completer.complete();
    });
    return completer.future;
  }

  Future<void> _connect() async {
    _running = true;
    var backoff = 1;
    while (!_disposed && !_stopped) {
      try {
        final response = await api.openEventStream('/api/v1/tasks/events');
        online = true;
        error = null;
        backoff = 1;
        notifyListeners();
        String? event;
        final data = StringBuffer();
        await for (final line
            in response
                .transform(utf8.decoder)
                .transform(const LineSplitter())) {
          if (_disposed || _stopped) break;
          if (line.isEmpty) {
            if (event != null) _dispatch(event, data.toString());
            event = null;
            data.clear();
            continue;
          }
          if (line.startsWith('event:')) {
            event = line.substring(6).trim();
          } else if (line.startsWith('data:')) {
            if (data.isNotEmpty) data.write('\n');
            data.write(line.substring(5).trim());
          }
        }
      } catch (err) {
        if (!_disposed && !_stopped) {
          online = false;
          error = err.toString();
          notifyListeners();
        }
      }
      if (_disposed || _stopped) break;
      await _waitBackoff(backoff);
      if (_stopped) break;
      backoff = min(30, backoff * 2);
    }
    _running = false;
  }

  void _dispatch(String event, String data) {
    if (event != 'snapshot' || data.isEmpty) return;
    try {
      final json = jsonDecode(data);
      if (json is! Map<String, dynamic>) return;
      final raw = json['tasks'];
      if (raw is! List) return;
      final next = <String, TaskSummary>{};
      for (final item in raw) {
        if (item is Map<String, dynamic>) {
          final task = TaskSummary.fromJson(item);
          if (task.id.isNotEmpty) next[task.id] = task;
        }
      }
      _tasks
        ..clear()
        ..addAll(next);
      notifyListeners();
    } on FormatException {
      // ignore malformed frames
    }
  }

  Future<TaskSummary> submit(
    String kind, {
    String? title,
    Map<String, dynamic>? params,
    String? idempotencyKey,
  }) async {
    final key = idempotencyKey ?? _newKey();
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final json = await api.postJson(
          '/api/v1/tasks',
          <String, dynamic>{
            'kind': kind,
            if (title != null && title.isNotEmpty) 'title': title,
            'params': ?params,
            'idempotency_key': key,
          },
          timeout: const Duration(seconds: 15),
        );
        if (json is! Map<String, dynamic>) {
          throw const ApiException(502, 'bad_response', '任务接口返回异常');
        }
        final task = TaskSummary.fromJson(
          (json['task'] as Map).cast<String, dynamic>(),
        );
        _tasks[task.id] = task;
        notifyListeners();
        return task;
      } on ApiException catch (err) {
        if (err.status < 500) rethrow;
        lastError = err;
      } catch (err) {
        lastError = err;
      }
      await Future<void>.delayed(Duration(milliseconds: 300 * (attempt + 1)));
    }
    throw lastError ?? Exception('提交任务失败');
  }

  Future<void> cancel(String id) async {
    await api.postJson('/api/v1/tasks/$id/cancel', null, timeout: const Duration(seconds: 10));
  }

  Future<void> dismiss(String id) async {
    await api.deleteJson('/api/v1/tasks/$id');
  }

  String _newKey() {
    final bytes = List<int>.generate(16, (_) => _random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  @override
  void dispose() {
    stop();
    _disposed = true;
    super.dispose();
  }
}
