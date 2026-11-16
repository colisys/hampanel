import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/api_client.dart';
import '../../core/models/docker.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

Future<void> showDockerJob(
  BuildContext context,
  ApiClient api,
  String jobId, {
  String title = '任务',
}) {
  return showDialog<void>(
    context: context,
    builder: (context) => _JobDialog(api: api, jobId: jobId, title: title),
  );
}

class _JobDialog extends StatefulWidget {
  const _JobDialog({
    required this.api,
    required this.jobId,
    required this.title,
  });

  final ApiClient api;
  final String jobId;
  final String title;

  @override
  State<_JobDialog> createState() => _JobDialogState();
}

class _JobDialogState extends State<_JobDialog> {
  DockerJob? _job;
  String? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _load());
  }

  Future<void> _load() async {
    try {
      final json = await widget.api.getJson(
        '/api/v1/docker/jobs/${widget.jobId}',
      );
      if (!mounted) return;
      final job = DockerJob.fromJson(json as Map<String, dynamic>);
      setState(() {
        _job = job;
        _error = null;
      });
      if (!job.running) _timer?.cancel();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = describeError(error));
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final job = _job;
    return AlertDialog(
      title: Text(widget.title),
      content: DialogBody(
        maxWidth: 820,
        maxHeight: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (job == null || job.running)
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (job != null && !job.running)
                  Icon(
                    job.status == 'succeeded'
                        ? Icons.check_circle_outline
                        : Icons.error_outline,
                    size: 16,
                    color: job.status == 'succeeded'
                        ? hampanelAccent
                        : hampanelDanger,
                  ),
                const SizedBox(width: 8),
                Text(
                  job == null ? '启动中…' : job.status,
                  style: const TextStyle(fontSize: 12),
                ),
                if (job?.exitCode != null) ...[
                  const SizedBox(width: 10),
                  Text(
                    'exit ${job!.exitCode}',
                    style: TextStyle(fontSize: 11, color: hampanelMuted),
                  ),
                ],
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(fontSize: 12, color: hampanelDanger),
              ),
            ],
            const SizedBox(height: 10),
            Expanded(
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: const Color(0xFF070B0E),
                  border: Border.all(color: hampanelBorder),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    (job?.output ?? '').isEmpty
                        ? '等待输出…'
                        : '${job!.truncated ? '…（仅显示末尾输出）\n' : ''}${job.output}',
                    style: monospace.copyWith(
                      fontSize: 11.5,
                      color: const Color(0xFFB8E6D0),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}
