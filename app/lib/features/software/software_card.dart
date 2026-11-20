import 'package:material_ui/material_ui.dart';

import '../../core/models/software.dart';
import '../../ui/theme.dart';
import '../../ui/widgets.dart';

class SoftwareCard extends StatelessWidget {
  const SoftwareCard({
    super.key,
    required this.item,
    required this.initializing,
    required this.onInitialize,
    this.dedicatedControls = false,
    required this.configPaths,
    required this.onEditConfig,
  });

  final SoftwareItem item;
  final bool initializing;
  final VoidCallback onInitialize;
  final bool dedicatedControls;
  final List<String> configPaths;
  final ValueChanged<String> onEditConfig;

  @override
  Widget build(BuildContext context) {
    return PanelCard(
      title: item.name,
      trailing: StatusPill(
        text: !item.installed
            ? '未安装'
            : item.needsInitialization
            ? '待初始化'
            : item.active
            ? '运行中'
            : '已托管',
        good: item.installed && !item.needsInitialization,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.description,
            style: TextStyle(fontSize: 12, color: hampanelMuted, height: 1.5),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 16,
            runSpacing: 4,
            children: [
              _meta('版本', item.version.isEmpty ? '-' : item.version),
              _meta('服务', item.service.isEmpty ? '-' : item.service),
              _meta('托管', item.initialized ? '已初始化' : '未初始化'),
            ],
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(
                item.manageHint,
                style: TextStyle(fontSize: 11.5, color: hampanelMuted),
              ),
              if (!item.installed)
                Text(
                  '请先在「应用商店 → 系统工具」安装',
                  style: TextStyle(fontSize: 11.5, color: hampanelMuted),
                )
              else if (item.needsInitialization && !dedicatedControls)
                FilledButton.icon(
                  onPressed: initializing ? null : onInitialize,
                  icon: initializing
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.settings_suggest_outlined, size: 16),
                  label: Text(item.initialized ? '重新初始化' : '初始化'),
                ),
            ],
          ),
          if (configPaths.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _showConfigMenu(context),
              icon: const Icon(Icons.edit_document, size: 16),
              label: const Text('编辑配置'),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _showConfigMenu(BuildContext context) async {
    if (configPaths.length == 1) {
      onEditConfig(configPaths.first);
      return;
    }
    final path = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final path in configPaths)
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: Text(path),
                onTap: () => Navigator.pop(context, path),
              ),
          ],
        ),
      ),
    );
    if (path != null) onEditConfig(path);
  }

  Widget _meta(String label, String value) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label: ', style: TextStyle(fontSize: 11, color: hampanelMuted)),
        SelectableText(value, style: monospace.copyWith(fontSize: 11)),
      ],
    );
  }
}
