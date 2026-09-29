// Adapted from vten lib/widgets/vten/features/chat/widgets/message_bubble.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: the full-message dialog is an in-pane expand. A dialog would
// paint over the native browser surface.

import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'styled_message_text.dart';

/// 1code-spec user message bubble: input-toned card, 1px border, 12px radius,
/// 12px/8px padding, 14px text. Tall content is clamped at
/// [maxCollapsedHeight] with a bottom fade into the bubble background.
/// Tapping a clamped bubble reveals the full message in place.
class UserMessageBubble extends StatefulWidget {
  const UserMessageBubble({
    super.key,
    required this.text,
    this.validAttachmentKeys,
  });

  final String text;
  final Set<String>? validAttachmentKeys;

  static const double maxCollapsedHeight = 100;
  static const double fadeHeight = 40;

  @override
  State<UserMessageBubble> createState() => _UserMessageBubbleState();
}

class _UserMessageBubbleState extends State<UserMessageBubble> {
  bool _clamped = false;
  bool _expanded = false;

  void _onContentHeight(double height) {
    final clamped = height > UserMessageBubble.maxCollapsedHeight + 0.5;
    if (clamped == _clamped) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _clamped != clamped) {
        setState(() => _clamped = clamped);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bubbleColor = Color.alphaBlend(
      theme.colorScheme.input.scaleAlpha(0.3),
      theme.colorScheme.background,
    );

    final content = _ChildHeightReporter(
      onHeight: _onContentHeight,
      child: StyledMessageText(
        text: widget.text,
        baseStyle: TextStyle(color: theme.colorScheme.foreground, fontSize: 14),
        validAttachmentKeys: widget.validAttachmentKeys,
      ),
    );

    final Widget body = _expanded || !_clamped
        ? content
        : SizedBox(
            height: UserMessageBubble.maxCollapsedHeight,
            child: Stack(
              clipBehavior: Clip.hardEdge,
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: IgnorePointer(child: content),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: UserMessageBubble.fadeHeight,
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            bubbleColor.withValues(alpha: 0),
                            bubbleColor,
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );

    final bubble = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bubbleColor,
        border: Border.all(color: theme.colorScheme.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: _expanded
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                body,
                GestureDetector(
                  onTap: () => setState(() => _expanded = false),
                  child: Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Show less',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.mutedForeground,
                      ),
                    ),
                  ),
                ),
              ],
            )
          : body,
    );

    if (!_clamped || _expanded) return bubble;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => setState(() => _expanded = true),
        child: bubble,
      ),
    );
  }
}

class _ChildHeightReporter extends SingleChildRenderObjectWidget {
  const _ChildHeightReporter({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderChildHeightReporter(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderChildHeightReporter renderObject,
  ) {
    renderObject.onHeight = onHeight;
  }
}

class _RenderChildHeightReporter extends RenderProxyBox {
  _RenderChildHeightReporter(this.onHeight);

  ValueChanged<double> onHeight;

  @override
  void performLayout() {
    super.performLayout();
    onHeight(size.height);
  }
}
