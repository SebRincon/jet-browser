import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Compact bordered icon control used by dock chrome and similar toolbars.
class ChromeIconButton extends StatefulWidget {
  const ChromeIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.selected = false,
    this.showBorder = true,
    this.size = 26,
    this.iconSize,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool selected;

  /// When false, only fill/hover coloring is shown (no outline border).
  final bool showBorder;

  /// Outer hit-target size. Default **26** for dock chrome; use **14** for
  /// dense pill close affordances (workspace switcher, etc.).
  final double size;

  /// Icon glyph size. Defaults to `size == 26 ? 14 : size * 0.65`.
  final double? iconSize;

  @override
  State<ChromeIconButton> createState() => _ChromeIconButtonState();
}

class _ChromeIconButtonState extends State<ChromeIconButton> {
  bool _hovering = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = widget.onPressed != null;
    final highlighted = widget.selected || _pressed;
    final fillColor = highlighted
        ? theme.colorScheme.muted
        : _hovering
        ? theme.colorScheme.muted.withValues(alpha: 0.55)
        : Colors.transparent;
    final iconColor = !enabled
        ? theme.colorScheme.mutedForeground.withValues(alpha: 0.45)
        : highlighted
        ? theme.colorScheme.foreground
        : theme.colorScheme.mutedForeground;
    final resolvedIconSize =
        widget.iconSize ?? (widget.size >= 22 ? 14.0 : widget.size * 0.65);
    final radius = widget.size >= 22 ? 6.0 : 3.0;

    return ChromeTooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) {
          if (!enabled) return;
          setState(() => _hovering = true);
        },
        onExit: (_) => setState(() {
          _hovering = false;
          _pressed = false;
        }),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
          onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
          onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            curve: Curves.easeOutCubic,
            width: widget.size,
            height: widget.size,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(radius),
              border: widget.showBorder
                  ? Border.all(
                      color: highlighted
                          ? theme.colorScheme.foreground.withValues(alpha: 0.45)
                          : _hovering
                          ? theme.colorScheme.border
                          : theme.colorScheme.border.withValues(alpha: 0.7),
                    )
                  : null,
            ),
            child: Icon(
              widget.icon,
              size: resolvedIconSize,
              color: iconColor,
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted popover-style tooltip for IDE chrome.
///
/// Matches context-menu / git tooltip theming (`popover` fill, border, soft
/// shadow) — not shadcn's default primary-blue [TooltipContainer].
class ChromeTooltip extends StatelessWidget {
  const ChromeTooltip({
    super.key,
    required this.message,
    required this.child,
    this.alignment = Alignment.topCenter,
    this.anchorAlignment = Alignment.bottomCenter,
  });

  final String message;
  final Widget child;
  final AlignmentGeometry alignment;
  final AlignmentGeometry anchorAlignment;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      alignment: alignment,
      anchorAlignment: anchorAlignment,
      waitDuration: const Duration(milliseconds: 400),
      showDuration: const Duration(milliseconds: 150),
      tooltip: (context) => _ChromeTooltipSurface(message: message),
      child: child,
    );
  }
}

class _ChromeTooltipSurface extends StatelessWidget {
  const _ChromeTooltipSurface({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.all(6),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.popover,
          border: Border.all(color: theme.colorScheme.border),
          borderRadius: BorderRadius.circular(6),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          child: Text(
            message,
            style: theme.typography.xSmall.copyWith(
              fontSize: 12,
              height: 1.18,
              color: theme.colorScheme.popoverForeground,
              fontWeight: FontWeight.normal,
            ),
          ),
        ),
      ),
    );
  }
}
