import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../ui/layout.dart';
import '../../ui/log_viewer.dart';
import '../../ui/widgets.dart';

class ServiceLogsPage extends StatefulWidget {
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
  State<ServiceLogsPage> createState() => _ServiceLogsPageState();
}

class _ServiceLogsPageState extends State<ServiceLogsPage> {
  String _content = '';
  String? _error;
  bool _loading = true;
  int _lines = 1000;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final json = await widget.api.getJson(
        '/api/v1/services/${widget.unit}/logs',
        query: {'lines': '$_lines'},
      );
      final map = json as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _content = map['lines'] as String? ?? '';
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = describeError(error);
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          DropdownButton<int>(
            value: _lines,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: 300, child: Text('300 行')),
              DropdownMenuItem(value: 1000, child: Text('1000 行')),
              DropdownMenuItem(value: 2000, child: Text('2000 行')),
            ],
            onChanged: (value) {
              if (value == null) return;
              setState(() => _lines = value);
              _load();
            },
          ),
          PageRefreshButton(onPressed: _load, refreshing: _loading),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
          ? Padding(
              padding: pageContentPadding(context),
              child: ErrorBanner(message: _error!, onRetry: _load),
            )
          : Padding(
              padding: pageContentPadding(context),
              child: LogViewer(
                content: _content,
                path: widget.unit,
                emptyMessage: '该服务暂无日志。',
              ),
            ),
    );
  }
}
