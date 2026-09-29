import 'package:shadcn_flutter/shadcn_flutter.dart';
import 'animated_collapse.dart';
import 'press_scale.dart';

class CollapsibleStepsWidget extends StatefulWidget {
  const CollapsibleStepsWidget({
    super.key,
    required this.stepsCount,
    required this.children,
    this.summary,
    this.defaultExpanded = false,
  });

  final int stepsCount;
  final List<Widget> children;
  final String? summary;
  final bool defaultExpanded;

  @override
  State<CollapsibleStepsWidget> createState() => _CollapsibleStepsWidgetState();
}

class _CollapsibleStepsWidgetState extends State<CollapsibleStepsWidget> {
  late bool _expanded;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _expanded = widget.defaultExpanded;
  }

  @override
  void didUpdateWidget(covariant CollapsibleStepsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.defaultExpanded != widget.defaultExpanded) {
      _expanded = widget.defaultExpanded;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.stepsCount == 0) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final headerStyle = theme.typography.p.copyWith(
      fontSize: 12,
      height: 1.2,
      color: theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w600,
    );

    final summaryStyle = headerStyle.copyWith(
      fontWeight: FontWeight.w400,
      color: theme.colorScheme.mutedForeground.withValues(alpha: 0.7),
    );
    final summary = widget.summary;

    final hoverColor = theme.colorScheme.muted.withValues(alpha: 0.2);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: PressScale(
            onTap: () => setState(() => _expanded = !_expanded),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: _hovered ? hoverColor : Colors.transparent,
                borderRadius: theme.borderRadiusSm,
              ),
              child: Row(
                children: [
                  Icon(
                    LucideIcons.listTree,
                    size: 14,
                    color: theme.colorScheme.mutedForeground,
                  ),
                  const Gap(6),
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          '${widget.stepsCount} '
                          '${widget.stepsCount == 1 ? 'step' : 'steps'}',
                          style: headerStyle,
                        ),
                        if (summary != null && summary.isNotEmpty) ...[
                          const Gap(6),
                          Flexible(
                            child: Text(
                              '· $summary',
                              style: summaryStyle,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  AnimatedChevron(
                    expanded: _expanded,
                    icon: Icon(
                      LucideIcons.chevronRight,
                      size: 14,
                      color: theme.colorScheme.mutedForeground.withValues(
                        alpha: 0.7,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        AnimatedCollapse(
          expanded: _expanded,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: widget.children,
            ),
          ),
        ),
      ],
    );
  }
}
