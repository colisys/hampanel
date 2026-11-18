import 'package:material_ui/material_ui.dart';

import '../../core/models/service.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class ServiceCard extends StatelessWidget {
  const ServiceCard({
    super.key,
    required this.service,
    required this.onAction,
    required this.onEdit,
    required this.onLogs,
  });

  final ServiceInfo service;
  final ValueChanged<String> onAction;
  final VoidCallback onEdit;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  service.unit,
                  style: monospace.copyWith(fontSize: 12.5),
                ),
                StatusPill(text: service.active, good: service.running),
                ServiceActions(
                  onAction: onAction,
                  onEdit: onEdit,
                  onLogs: onLogs,
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              service.description.isEmpty
                  ? service.sub
                  : service.description,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: hampanelMuted,
                height: 1.45,
              ),
            ),
            if (service.description.isNotEmpty) ...[
              const SizedBox(height: 3),
              Text(
                service.sub,
                style: TextStyle(fontSize: 10.5, color: hampanelMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class ServiceActions extends StatelessWidget {
  const ServiceActions({
    super.key,
    required this.onAction,
    required this.onEdit,
    required this.onLogs,
  });

  final ValueChanged<String> onAction;
  final VoidCallback onEdit;
  final VoidCallback onLogs;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        PopupMenuButton<String>(
          tooltip: '操作',
          icon: const Icon(Icons.more_horiz, size: 18),
          onSelected: onAction,
          itemBuilder: (context) => const [
            PopupMenuItem(value: 'start', child: Text('启动')),
            PopupMenuItem(value: 'stop', child: Text('停止')),
            PopupMenuItem(value: 'restart', child: Text('重启')),
            PopupMenuItem(value: 'reload', child: Text('重载')),
            PopupMenuItem(value: 'enable', child: Text('开机自启')),
            PopupMenuItem(value: 'disable', child: Text('取消自启')),
          ],
        ),
        IconButton(
          tooltip: '编辑配置',
          visualDensity: VisualDensity.compact,
          onPressed: onEdit,
          icon: const Icon(Icons.edit_outlined, size: 18),
        ),
        IconButton(
          tooltip: '日志',
          visualDensity: VisualDensity.compact,
          onPressed: onLogs,
          icon: const Icon(Icons.receipt_long_outlined, size: 18),
        ),
      ],
    );
  }
}
