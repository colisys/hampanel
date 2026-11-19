import 'package:material_ui/material_ui.dart';

import 'theme.dart';
import 'widgets.dart';

const double kCompactBreakpoint = 720;
const double kDesktopBreakpoint = 1080;

/// One horizontal page padding for headers, lists and cards.
///
/// SSH/files/firewall use 12 on phones and 24 elsewhere; every page should use
/// this helper instead of hard-coding a separate inset.
EdgeInsets pageContentPadding(BuildContext context, {double top = 4}) {
  final compact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
  final horizontal = compact ? 12.0 : 24.0;
  return EdgeInsets.fromLTRB(horizontal, top, horizontal, 24);
}

class PageRefreshButton extends StatelessWidget {
  const PageRefreshButton({
    super.key,
    required this.onPressed,
    this.refreshing = false,
    this.tooltip = '刷新',
  });

  final VoidCallback? onPressed;
  final bool refreshing;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      onPressed: refreshing ? null : onPressed,
      icon: refreshing
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.refresh, size: 20),
    );
  }
}

class ActionDockItem {
  const ActionDockItem({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;
  final bool danger;
}

/// Mobile bottom action rail. Keeps page actions reachable with one thumb
/// while the header stays focused on title and refresh.
class ActionDock extends StatelessWidget {
  const ActionDock({super.key, required this.actions});

  final List<ActionDockItem> actions;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: hampanelSurface,
        border: Border(top: BorderSide(color: hampanelBorder, width: 1.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            itemCount: actions.length,
            separatorBuilder: (_, _) => const SizedBox(width: 2),
            itemBuilder: (context, index) => _DockButton(item: actions[index]),
          ),
        ),
      ),
    );
  }
}

class _DockButton extends StatelessWidget {
  const _DockButton({required this.item});

  final ActionDockItem item;

  @override
  Widget build(BuildContext context) {
    final color = item.danger ? hampanelDanger : hampanelInk;
    final enabled = item.onPressed != null;
    return InkWell(
      onTap: item.onPressed,
      borderRadius: BorderRadius.circular(2),
      child: SizedBox(
        width: 64,
        child: Opacity(
          opacity: enabled ? 1 : 0.35,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(item.icon, size: 20, color: color),
              const SizedBox(height: 3),
              Text(
                item.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Full-width bottom navigation. Each item takes an equal share, unlike
/// [SubNavMenu], which shrinks to its label and leaves the rest of the rail
/// empty.
class SubNavBar extends StatelessWidget {
  const SubNavBar({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
  });

  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < items.length; i++)
          Expanded(
            child: InkWell(
              onTap: () => onChanged(i),
              borderRadius: BorderRadius.circular(2),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      items[i],
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: i == index
                            ? FontWeight.w700
                            : FontWeight.w500,
                        color: i == index ? hampanelAccent : hampanelMuted,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      height: 2,
                      width: 18,
                      color: i == index ? hampanelAccent : Colors.transparent,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// A metric tile shared by the Docker overview and dashboard.
class MetricCard extends StatelessWidget {
  const MetricCard({
    super.key,
    required this.label,
    required this.value,
    this.detail,
    this.icon,
    this.accent,
  });

  final String label;
  final String value;
  final String? detail;
  final IconData? icon;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(boxShadow: mangaShadowSmall),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: hampanelMuted,
                      ),
                    ),
                  ),
                  if (icon != null)
                    Icon(
                      icon,
                      size: 15,
                      color: accent ?? hampanelMuted,
                    ),
                ],
              ),
              const SizedBox(height: 7),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: accent ?? hampanelInk,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              if (detail != null) ...[
                const SizedBox(height: 3),
                Text(
                  detail!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 10.5, color: hampanelMuted),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// Responsive 2-column (phone) / 4-column (desktop) metric grid.
class MetricGrid extends StatelessWidget {
  const MetricGrid({
    super.key,
    required this.metrics,
    this.spacing = 12,
    this.wideColumns = 4,
  });

  final List<MetricCard> metrics;
  final double spacing;
  final int wideColumns;

  @override
  Widget build(BuildContext context) {
    if (metrics.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 620 ? 2 : wideColumns;
        final width =
            (constraints.maxWidth - spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: [
            for (final metric in metrics)
              SizedBox(width: width, child: metric),
          ],
        );
      },
    );
  }
}

/// Page shell used by pages that need a header, responsive refresh and a
/// bottom action rail on phones.
class SectionScaffold extends StatelessWidget {
  const SectionScaffold({
    super.key,
    required this.title,
    this.subtitle,
    this.headerActions = const [],
    this.dockActions = const [],
    this.refreshing = false,
    this.onRefresh,
    required this.child,
  });

  final String title;
  final String? subtitle;
  final List<Widget> headerActions;
  final List<ActionDockItem> dockActions;
  final bool refreshing;
  final VoidCallback? onRefresh;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < kCompactBreakpoint;
    return Column(
      children: [
        PageHeader(
          title: title,
          subtitle: subtitle,
          actions: [
            if (onRefresh != null)
              PageRefreshButton(
                onPressed: onRefresh,
                refreshing: refreshing,
              ),
            if (!compact) ...headerActions,
          ],
        ),
        Expanded(child: child),
        if (compact && dockActions.isNotEmpty) ActionDock(actions: dockActions),
      ],
    );
  }
}
