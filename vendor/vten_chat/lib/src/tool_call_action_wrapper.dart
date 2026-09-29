// Adapted from vten lib/widgets/vten/features/chat/widgets/tool_call_action_wrapper.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: ToolCall/ToolResult replaced by [ChatToolSummary]. The row
// always keeps the compact header and slides the host child open. A failure
// badge is drawn on the vten compact row so errors stay visible.

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'animated_collapse.dart';
import 'chat_ui_config.dart';
import 'press_scale.dart';
import 'text_shimmer.dart';

class ChatToolSummary {
  const ChatToolSummary({
    required this.title,
    this.pathText,
    this.detail = '',
    this.meta,
    this.additions = 0,
    this.removals = 0,
  });

  final String title;
  final String? pathText;
  final String detail;
  final String? meta;
  final int additions;
  final int removals;
}

class ToolCallActionWrapper extends StatefulWidget {
  const ToolCallActionWrapper({
    super.key,
    required this.summary,
    required this.child,
    this.pending = false,
    this.failed = false,
    this.interrupted = false,
  });

  final ChatToolSummary summary;
  final Widget child;
  final bool pending;
  final bool failed;
  final bool interrupted;

  @override
  State<ToolCallActionWrapper> createState() => _ToolCallActionWrapperState();
}

class _ToolCallActionWrapperState extends State<ToolCallActionWrapper> {
  bool _expanded = false;
  bool _userToggled = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_userToggled) return;
    final ui = VtenChatUiConfig.of(context);
    _expanded = ui.toolCallsDefaultExpanded && !ui.compactToolCalls;
  }

  void _setExpanded(bool value) {
    setState(() {
      _expanded = value;
      _userToggled = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ui = VtenChatUiConfig.of(context);
    final isMobile = ui.layoutMode == VtenChatUiLayoutMode.mobile;
    final marginTop = isMobile ? 3.0 : 2.0;
    final vten = ui.compactStyle == VtenChatUiCompactStyle.vten;
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.only(top: marginTop),
              child: vten
                  ? VcodeCompactToolCallRow(
                      summary: widget.summary,
                      pending: widget.pending,
                      failed: widget.failed,
                      interrupted: widget.interrupted,
                      expanded: _expanded,
                      onTap: () => _setExpanded(!_expanded),
                    )
                  : CompactToolCallRow(
                      summary: widget.summary,
                      pending: widget.pending,
                      failed: widget.failed,
                      interrupted: widget.interrupted,
                      expanded: _expanded,
                      onTap: () => _setExpanded(!_expanded),
                    ),
            ),
            AnimatedCollapse(expanded: _expanded, child: widget.child),
          ],
        ),
      ),
    );
  }
}

Color diffAdditionTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.brightness == Brightness.dark
        ? const Color(0xFF4ADE80)
        : const Color(0xFF16A34A);

Color diffRemovalTextColor(BuildContext context) =>
    Theme.of(context).colorScheme.brightness == Brightness.dark
        ? const Color(0xFFF87171)
        : const Color(0xFFDC2626);

class CompactToolCallRow extends StatefulWidget {
  const CompactToolCallRow({
    super.key,
    required this.summary,
    required this.onTap,
    this.pending = false,
    this.failed = false,
    this.interrupted = false,
    this.expanded = false,
  });

  final ChatToolSummary summary;
  final bool pending;
  final bool failed;
  final bool interrupted;
  final bool expanded;
  final VoidCallback onTap;

  @override
  State<CompactToolCallRow> createState() => _CompactToolCallRowState();
}

class _CompactToolCallRowState extends State<CompactToolCallRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ui = VtenChatUiConfig.of(context);
    final isMobile = ui.layoutMode == VtenChatUiLayoutMode.mobile;
    final summary = widget.summary;
    final baseStyle = theme.typography.p.copyWith(fontSize: 12, height: 1.25);
    final titleStyle = baseStyle.copyWith(
      color: theme.colorScheme.foreground.withValues(alpha: 0.7),
      fontWeight: FontWeight.w400,
    );
    final metaStyle = baseStyle.copyWith(
      color: theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w400,
    );
    final pathStyle = theme.typography.mono.copyWith(
      fontFamily: 'GeistMono',
      fontSize: 11.5,
      height: 1.25,
      color: theme.colorScheme.foreground.withValues(alpha: 0.85),
      fontWeight: FontWeight.w400,
    );
    final rowPadding = isMobile
        ? const EdgeInsets.symmetric(horizontal: 6, vertical: 4)
        : const EdgeInsets.symmetric(horizontal: 6, vertical: 3);
    final trailing = (!widget.interrupted && widget.failed)
        ? Icon(
            LucideIcons.badgeAlert,
            size: 16,
            color: theme.colorScheme.destructive,
          )
        : null;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: PressScale(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: rowPadding,
          decoration: BoxDecoration(
            color: _hovered
                ? theme.colorScheme.muted.withValues(alpha: 0.25)
                : Colors.transparent,
            borderRadius: theme.borderRadiusSm,
          ),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (widget.interrupted)
                        TextSpan(
                          text: '${summary.title} interrupted',
                          style: metaStyle,
                        )
                      else if (widget.pending)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: TextShimmer(
                            text: summary.title,
                            style: titleStyle,
                          ),
                        )
                      else
                        TextSpan(text: summary.title, style: titleStyle),
                      ..._summaryDetailSpans(
                        summary,
                        pathStyle: pathStyle,
                        metaStyle: metaStyle,
                        additionStyle: pathStyle.copyWith(
                          color: diffAdditionTextColor(context),
                        ),
                        removalStyle: pathStyle.copyWith(
                          color: diffRemovalTextColor(context),
                        ),
                      ),
                      WidgetSpan(
                        alignment: PlaceholderAlignment.middle,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: AnimatedChevron(
                            expanded: widget.expanded,
                            icon: Icon(
                              LucideIcons.chevronRight,
                              size: 12,
                              color: theme.colorScheme.mutedForeground
                                  .withValues(alpha: _hovered ? 1 : 0.7),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) ...[const Gap(10), trailing],
            ],
          ),
        ),
      ),
    );
  }
}

List<InlineSpan> _summaryDetailSpans(
  ChatToolSummary summary, {
  required TextStyle pathStyle,
  required TextStyle metaStyle,
  TextStyle? additionStyle,
  TextStyle? removalStyle,
}) {
  final spans = <InlineSpan>[];
  final pathText = summary.pathText ?? '';
  var hasContent = false;
  if (pathText.isNotEmpty) {
    spans.add(const TextSpan(text: '  '));
    spans.add(TextSpan(text: pathText, style: pathStyle));
    hasContent = true;
  }
  if (additionStyle != null && summary.additions != 0) {
    spans.add(TextSpan(text: hasContent ? ' ' : '  '));
    spans.add(TextSpan(text: '+${summary.additions}', style: additionStyle));
    hasContent = true;
  }
  if (removalStyle != null && summary.removals != 0) {
    spans.add(TextSpan(text: hasContent ? ' ' : '  '));
    spans.add(TextSpan(text: '-${summary.removals}', style: removalStyle));
    hasContent = true;
  }
  if (summary.detail.isNotEmpty) {
    spans.add(TextSpan(text: hasContent ? ' ' : '  '));
    spans.add(TextSpan(text: summary.detail, style: metaStyle));
    hasContent = true;
  }
  final meta = summary.meta ?? '';
  if (meta.isNotEmpty) {
    spans.add(TextSpan(text: hasContent ? ' · ' : '  ', style: metaStyle));
    spans.add(TextSpan(text: meta, style: metaStyle));
  }
  return spans;
}

class VcodeCompactToolCallRow extends StatefulWidget {
  const VcodeCompactToolCallRow({
    super.key,
    required this.summary,
    required this.onTap,
    this.pending = false,
    this.failed = false,
    this.interrupted = false,
    this.expanded = false,
  });

  final ChatToolSummary summary;
  final bool pending;
  final bool failed;
  final bool interrupted;
  final bool expanded;
  final VoidCallback onTap;

  @override
  State<VcodeCompactToolCallRow> createState() =>
      _VcodeCompactToolCallRowState();
}

class _VcodeCompactToolCallRowState extends State<VcodeCompactToolCallRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ui = VtenChatUiConfig.of(context);
    final isMobile = ui.layoutMode == VtenChatUiLayoutMode.mobile;
    final summary = widget.summary;
    final baseStyle = theme.typography.p.copyWith(
      fontSize: 12,
      height: 1.2,
      color: theme.colorScheme.mutedForeground,
    );
    final titleStyle = baseStyle.copyWith(
      color: widget.failed
          ? theme.colorScheme.destructive
          : theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w600,
    );
    final metaStyle = baseStyle.copyWith(
      color: theme.colorScheme.mutedForeground.withValues(alpha: 0.7),
      fontWeight: FontWeight.w400,
    );
    final pathStyle = theme.typography.mono.copyWith(
      fontFamily: 'GeistMono',
      fontSize: 11.5,
      height: 1.2,
      color: theme.colorScheme.mutedForeground,
      fontWeight: FontWeight.w400,
    );
    final showChevron = _hovered || isMobile || widget.expanded;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: PressScale(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          child: Row(
            children: [
              Expanded(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (widget.pending && !widget.interrupted)
                        WidgetSpan(
                          alignment: PlaceholderAlignment.baseline,
                          baseline: TextBaseline.alphabetic,
                          child: TextShimmer(
                            text: summary.title,
                            style: titleStyle,
                          ),
                        )
                      else
                        TextSpan(
                          text: widget.interrupted
                              ? '${summary.title} interrupted'
                              : summary.title,
                          style: titleStyle,
                        ),
                      ..._summaryDetailSpans(
                        summary,
                        pathStyle: pathStyle,
                        metaStyle: metaStyle,
                        additionStyle: pathStyle.copyWith(
                          color: diffAdditionTextColor(context),
                        ),
                        removalStyle: pathStyle.copyWith(
                          color: diffRemovalTextColor(context),
                        ),
                      ),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (widget.failed) ...[
                const Gap(6),
                Icon(
                  LucideIcons.badgeAlert,
                  size: 14,
                  color: theme.colorScheme.destructive,
                ),
              ],
              const Gap(6),
              Opacity(
                opacity: showChevron ? 1 : 0,
                child: AnimatedChevron(
                  expanded: widget.expanded,
                  icon: Icon(
                    LucideIcons.chevronRight,
                    size: 14,
                    color: theme.colorScheme.mutedForeground.withValues(
                      alpha: 0.6,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
