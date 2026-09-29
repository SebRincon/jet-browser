// Adapted from vten lib/widgets/vten/features/chat/widgets/compact_config_selector.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: only the model chip is kept. Mode, effort, and provider
// popovers are IDE controls and are not presented as working.

import 'package:flutter/material.dart' as material;
import 'package:shadcn_flutter/shadcn_flutter.dart';

class CompactConfigSelector extends StatefulWidget {
  const CompactConfigSelector({
    super.key,
    required this.label,
    required this.onPressed,
    this.selected = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool selected;

  @override
  State<CompactConfigSelector> createState() => _CompactConfigSelectorState();
}

class _CompactConfigSelectorState extends State<CompactConfigSelector> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.muted.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: theme.colorScheme.border.withValues(alpha: 0.5),
        ),
      ),
      child: material.MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: widget.onPressed == null
            ? material.SystemMouseCursors.basic
            : material.SystemMouseCursors.click,
        child: material.GestureDetector(
          onTap: widget.onPressed,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: widget.selected || _hovered
                  ? theme.colorScheme.muted.withValues(alpha: 0.7)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  LucideIcons.bot,
                  size: 14,
                  color: theme.colorScheme.mutedForeground,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.mutedForeground,
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Icon(
                  LucideIcons.chevronUp,
                  size: 12,
                  color: theme.colorScheme.mutedForeground.withValues(
                    alpha: 0.7,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
