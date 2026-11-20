import 'package:material_ui/material_ui.dart';

class SelectionToolbar extends StatelessWidget {
  const SelectionToolbar({
    super.key,
    required this.visible,
    required this.selected,
    required this.onChanged,
    this.enabled = true,
  });
  final Set<String> visible, selected;
  final ValueChanged<Set<String>> onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    children: [
      TextButton(
        onPressed: enabled && !selected.containsAll(visible)
            ? () => onChanged(selected.union(visible))
            : null,
        child: const Text('全选'),
      ),
      TextButton(
        onPressed: enabled && visible.isNotEmpty
            ? () => onChanged(
                selected
                    .difference(visible)
                    .union(visible.difference(selected)),
              )
            : null,
        child: const Text('反选'),
      ),
      TextButton(
        onPressed: enabled && selected.isNotEmpty ? () => onChanged({}) : null,
        child: const Text('清空'),
      ),
    ],
  );
}
