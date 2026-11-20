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
        padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(service.unit, style: monospace.copyWith(fontSize: 13)),
            const SizedBox(height: 6),
            Wrap(
              spacing: 12,
              runSpacing: 4,
              children: [
                Text(
                  service.sub,
                  style: monospace.copyWith(fontSize: 11, color: hampanelMuted),
                ),
                if (service.description.isNotEmpty)
                  Text(
                    service.description,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: hampanelMuted,
                      height: 1.45,
                    ),
                  ),
              ],
            ),
            StatusPill(text: service.active, good: service.running),
            ServiceActions(onAction: onAction, onEdit: onEdit, onLogs: onLogs),
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
    return PopupMenuButton<String>(
      tooltip: '服务操作',
      icon: const Icon(Icons.more_horiz, size: 19),
      onSelected: (value) {
        switch (value) {
          case 'edit':
            onEdit();
          case 'logs':
            onLogs();
          default:
            onAction(value);
        }
      },
      itemBuilder: (context) => const [
        PopupMenuItem(value: 'edit', child: Text('编辑配置')),
        PopupMenuItem(value: 'logs', child: Text('查看日志')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'start', child: Text('启动')),
        PopupMenuItem(value: 'stop', child: Text('停止')),
        PopupMenuItem(value: 'restart', child: Text('重启')),
        PopupMenuItem(value: 'reload', child: Text('重载')),
        PopupMenuItem(value: 'enable', child: Text('开机自启')),
        PopupMenuItem(value: 'disable', child: Text('取消自启')),
      ],
    );
  }
}
