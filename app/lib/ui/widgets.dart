import 'package:material_ui/material_ui.dart';

import 'theme.dart';

class PageHeader extends StatelessWidget {
  const PageHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.actions = const [],
  });

  final String title;
  final String? subtitle;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compact = width < 720;
    final stacked = width < 900 && actions.length > 1;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(width: 5, height: 22, color: hampanelAccent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 23,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.4,
                ),
              ),
            ),
          ],
        ),
        if (subtitle != null) ...[
          const SizedBox(height: 4),
          Text(
            subtitle!,
            style: TextStyle(fontSize: 12.5, color: hampanelMuted),
          ),
        ],
      ],
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        compact ? 12 : 24,
        20,
        compact ? 12 : 24,
        12,
      ),
      child: stacked
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                titleBlock,
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: actions,
                ),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(child: titleBlock),
                ...actions,
              ],
            ),
    );
  }
}

class PanelCard extends StatelessWidget {
  const PanelCard({
    super.key,
    this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final String? title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(boxShadow: mangaShadowSmall),
      child: Card(
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (title != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      Container(width: 6, height: 6, color: hampanelAccent),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          title!,
                          style: const TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      ?trailing,
                    ],
                  ),
                ),
              child,
            ],
          ),
        ),
      ),
    );
  }
}

class StatTile extends StatelessWidget {
  const StatTile({
    super.key,
    required this.label,
    required this.value,
    this.detail,
    this.accent,
  });

  final String label;
  final String value;
  final String? detail;
  final Color? accent;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: hampanelMuted,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: accent ?? hampanelInk,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (detail != null) ...[
          const SizedBox(height: 4),
          Text(detail!, style: TextStyle(fontSize: 11, color: hampanelMuted)),
        ],
      ],
    );
  }
}

class StyledProgress extends StatelessWidget {
  const StyledProgress({super.key, required this.value, this.color});

  final double value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: hampanelInk, width: 1.5),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(1),
        child: LinearProgressIndicator(
          value: value.clamp(0, 1),
          minHeight: 9,
          backgroundColor: hampanelSurfaceAlt,
          valueColor: AlwaysStoppedAnimation<Color>(color ?? hampanelInk),
        ),
      ),
    );
  }
}

class ErrorBanner extends StatelessWidget {
  const ErrorBanner({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      decoration: BoxDecoration(boxShadow: mangaShadowSmall),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: hampanelSurface,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: hampanelDanger, width: 2),
        ),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: hampanelDanger, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: hampanelInk,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (onRetry != null)
              TextButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    );
  }
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SizedBox(
        width: 22,
        height: 22,
        child: CircularProgressIndicator(strokeWidth: 2.2),
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: hampanelSurfaceAlt,
                border: Border.all(color: hampanelInk, width: 2),
              ),
              child: Icon(icon, size: 28, color: hampanelInk),
            ),
            SizedBox(height: 14),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
            if (message != null) ...[
              SizedBox(height: 6),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: hampanelMuted),
              ),
            ],
            if (action != null) ...[SizedBox(height: 16), action!],
          ],
        ),
      ),
    );
  }
}

class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.text, required this.good});

  final String text;
  final bool good;

  @override
  Widget build(BuildContext context) {
    final color = good ? hampanelInk : hampanelDanger;
    return Container(
      padding: EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: good
            ? hampanelSurfaceAlt
            : hampanelDanger.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          fontFamily: 'monospace',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: color,
        ),
      ),
    );
  }
}

/// Shows a snackbar after removing the current one, so a stale toast cannot
/// keep every later message queued and invisible.
void showAppSnackBar(BuildContext context, SnackBar snackBar) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.removeCurrentSnackBar();
  messenger.showSnackBar(snackBar);
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = '确认',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text('取消'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: hampanelDanger)
              : null,
          onPressed: () => Navigator.pop(context, true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

Future<String?> textInputDialog(
  BuildContext context, {
  required String title,
  required String label,
  String initial = '',
  bool multiline = false,
  String confirmLabel = '确定',
}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: DialogBody(
        maxWidth: 460,
        child: TextField(
          controller: controller,
          autofocus: true,
          minLines: multiline ? 4 : 1,
          maxLines: multiline ? 12 : 1,
          decoration: InputDecoration(labelText: label),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(context, controller.text),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  controller.dispose();
  return result;
}

/// Comic screentone: a sparse dot grid used as the empty-state backdrop.
class Halftone extends StatelessWidget {
  const Halftone({
    super.key,
    this.color,
    this.spacing = 15,
    this.dotRadius = 1.1,
    this.opacity = 0.09,
    this.child,
  });

  final Color? color;
  final double spacing;
  final double dotRadius;
  final double opacity;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _HalftonePainter(
        color: (color ?? hampanelInk).withValues(alpha: opacity),
        spacing: spacing,
        dotRadius: dotRadius,
      ),
      child: child,
    );
  }
}

class _HalftonePainter extends CustomPainter {
  const _HalftonePainter({
    required this.color,
    required this.spacing,
    required this.dotRadius,
  });

  final Color color;
  final double spacing;
  final double dotRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    var row = 0;
    for (var y = 0.0; y < size.height + spacing; y += spacing) {
      final offset = row.isOdd ? spacing / 2 : 0.0;
      for (var x = offset; x < size.width + spacing; x += spacing) {
        canvas.drawCircle(Offset(x, y), dotRadius, paint);
      }
      row++;
    }
  }

  @override
  bool shouldRepaint(_HalftonePainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.spacing != spacing ||
      oldDelegate.dotRadius != dotRadius;
}

/// 页面内的二级导航，渲染在内容区左侧，与一级侧栏形成层级。
class SubNav extends StatelessWidget {
  const SubNav({
    super.key,
    required this.items,
    required this.index,
    required this.onChanged,
    this.width = 168,
  });

  final List<String> items;
  final int index;
  final ValueChanged<int> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      margin: const EdgeInsets.fromLTRB(12, 4, 0, 24),
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          for (var i = 0; i < items.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: InkWell(
                onTap: () => onChanged(i),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 9,
                  ),
                  decoration: BoxDecoration(
                    color: i == index ? hampanelSurfaceAlt : null,
                    border: Border(
                      left: BorderSide(
                        color: i == index ? hampanelAccent : Colors.transparent,
                        width: 3,
                      ),
                    ),
                  ),
                  child: Text(
                    items[i],
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: i == index
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: i == index ? hampanelInk : hampanelMuted,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 窄屏下的二级菜单入口：只占一个小汉堡按钮，点击弹出同级选项。
class SubNavMenu extends StatelessWidget {
  const SubNavMenu({
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
    return PopupMenuButton<int>(
      tooltip: '切换子菜单',
      onSelected: onChanged,
      itemBuilder: (context) => [
        for (var i = 0; i < items.length; i++)
          PopupMenuItem(value: i, child: Text(items[i])),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          border: Border.all(color: hampanelInk, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.menu, size: 15),
            const SizedBox(width: 6),
            Text(
              items[index],
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            const Icon(Icons.arrow_drop_down, size: 18),
          ],
        ),
      ),
    );
  }
}

/// 对话框主体：桌面维持设计宽度，窄屏自动收窄到可用空间，避免横向溢出。
class DialogBody extends StatelessWidget {
  const DialogBody({
    super.key,
    required this.maxWidth,
    this.maxHeight,
    required this.child,
  });

  final double maxWidth;
  final double? maxHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final width = maxWidth < size.width - 48 ? maxWidth : size.width - 48;
    if (maxHeight == null) return SizedBox(width: width, child: child);
    final height = maxHeight! < size.height - 96
        ? maxHeight!
        : size.height - 96;
    return SizedBox(width: width, height: height, child: child);
  }
}

/// Lays form controls side by side on wide layouts and one per line on
/// phones. Side-by-side text fields become unusably narrow on a phone.
class FormRow extends StatelessWidget {
  const FormRow({
    super.key,
    required this.children,
    this.flex,
    this.spacing = 10,
    this.breakpoint = 720,
  });

  final List<Widget> children;
  final List<int>? flex;
  final double spacing;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < breakpoint;
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) SizedBox(height: spacing),
            children[i],
          ],
        ],
      );
    }
    final widths = flex;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) SizedBox(width: spacing),
          Expanded(
            flex: widths != null && i < widths.length ? widths[i] : 1,
            child: children[i],
          ),
        ],
      ],
    );
  }
}

/// A field followed by trailing buttons: full-width field with wrapped
/// actions below on phones, a single row on desktop.
class FieldWithActions extends StatelessWidget {
  const FieldWithActions({
    super.key,
    required this.field,
    required this.actions,
    this.spacing = 10,
    this.breakpoint = 720,
  });

  final Widget field;
  final List<Widget> actions;
  final double spacing;
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < breakpoint;
    if (compact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          field,
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.end,
            children: actions,
          ),
        ],
      );
    }
    return Row(
      children: [
        Expanded(child: field),
        for (final action in actions) ...[SizedBox(width: spacing), action],
      ],
    );
  }
}
