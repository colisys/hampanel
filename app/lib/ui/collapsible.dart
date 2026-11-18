import 'package:material_ui/material_ui.dart';

import 'theme.dart';

/// Collapsible block for long lists of secondary settings.
///
/// Pass [expanded] to control it from the page (for "expand all" / "collapse
/// all"); otherwise it keeps its own state starting at [initiallyExpanded].
class CollapsibleSection extends StatefulWidget {
  const CollapsibleSection({
    super.key,
    required this.title,
    this.subtitle,
    this.trailing,
    this.initiallyExpanded = false,
    this.expanded,
    this.onChanged,
    this.padding = const EdgeInsets.only(top: 8),
    required this.child,
  });

  final String title;
  final String? subtitle;
  final Widget? trailing;
  final bool initiallyExpanded;
  final bool? expanded;
  final ValueChanged<bool>? onChanged;
  final EdgeInsets padding;
  final Widget child;

  @override
  State<CollapsibleSection> createState() => _CollapsibleSectionState();
}

class _CollapsibleSectionState extends State<CollapsibleSection> {
  late bool _expanded;

  bool get _isExpanded => widget.expanded ?? _expanded;

  @override
  void initState() {
    super.initState();
    _expanded = widget.initiallyExpanded;
  }

  @override
  void didUpdateWidget(covariant CollapsibleSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.expanded != null && oldWidget.expanded != widget.expanded) {
      _expanded = widget.expanded!;
    }
  }

  void _toggle() {
    final next = !_isExpanded;
    if (widget.expanded == null) {
      setState(() => _expanded = next);
    }
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final expanded = _isExpanded;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(2),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 9),
            child: Row(
              children: [
                AnimatedRotation(
                  turns: expanded ? 0.25 : 0,
                  duration: const Duration(milliseconds: 160),
                  child: Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: hampanelMuted,
                  ),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.title,
                        style: const TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (widget.subtitle != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            widget.subtitle!,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: hampanelMuted,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                ?widget.trailing,
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topCenter,
          child: expanded
              ? Padding(
                  padding: widget.padding,
                  child: widget.child,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}
