import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../ui/log_page.dart';

/// Service journal logs. Thin wrapper over the shared [LogPage] so every log
/// viewer in the app shares the same filters and layout.
class ServiceLogsPage extends StatelessWidget {
  const ServiceLogsPage({
    super.key,
    required this.api,
    required this.unit,
    required this.title,
  });

  final ApiClient api;
  final String unit;
  final String title;

  @override
  Widget build(BuildContext context) {
    return LogPage(
      title: title,
      emptyMessage: '该服务暂无日志。',
      load: (lines) async {
        final json = await api.getJson(
          '/api/v1/services/$unit/logs',
          query: {'lines': '$lines'},
        );
        final map = json as Map<String, dynamic>? ?? const {};
        return LogPageData(
          content: map['lines'] as String? ?? '',
          path: unit,
        );
      },
    );
  }
}
