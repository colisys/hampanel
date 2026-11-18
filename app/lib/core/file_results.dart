void requireDeleted(dynamic json, List<String> paths) {
  if (json is! Map || json['results'] is! List) {
    throw StateError('删除失败：缺少逐项结果');
  }
  final results = json['results'] as List;
  final failures = <String>[];
  for (final path in paths) {
    final matches = results.whereType<Map>().where((item) => item['path'] == path);
    if (matches.length != 1 || matches.single['ok'] != true) {
      final message = matches.isEmpty ? '缺少结果' : matches.first['message'] ?? '删除失败';
      failures.add('$path: $message');
    }
  }
  for (final item in results.whereType<Map>()) {
    if (item['ok'] != true && !paths.contains(item['path'])) {
      failures.add('${item['path']}: ${item['message'] ?? '删除失败'}');
    }
  }
  if (failures.isNotEmpty) throw StateError(failures.join('\n'));
}
