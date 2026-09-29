import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

/// Keeps a readable browser column. Tiny windows shrink the chat to zero
/// instead of producing a negative width.
double clampChatWidth(double preferred, double windowWidth,
    {double reserved = 6}) {
  const minBrowser = 320.0;
  const minChat = 280.0;
  final room = math.max(0.0, windowWidth - reserved);
  final maxChat = math.max(0.0, room - minBrowser);
  if (maxChat <= 0) return 0;
  if (maxChat < minChat) return maxChat;
  final next = preferred.clamp(minChat, maxChat);
  return next.toDouble();
}

class ChatResizeHandle extends StatelessWidget {
  const ChatResizeHandle({super.key, required this.onAdjust});
  final ValueChanged<double> onAdjust;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Resize chat',
      slider: true,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.resizeColumn,
        actions: {
          NarrowChatIntent:
              CallbackAction<NarrowChatIntent>(onInvoke: (_) => onAdjust(-24)),
          WidenChatIntent:
              CallbackAction<WidenChatIntent>(onInvoke: (_) => onAdjust(24)),
        },
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.arrowLeft): WidenChatIntent(),
          SingleActivator(LogicalKeyboardKey.arrowRight): NarrowChatIntent(),
        },
        child: GestureDetector(
          key: const ValueKey('chat-resize'),
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (details) => onAdjust(-details.delta.dx),
          child: Tooltip(
            alignment: Alignment.bottomCenter,
            anchorAlignment: Alignment.topCenter,
            tooltip: (_) => const TooltipContainer(child: Text('Resize chat')),
            child: Builder(builder: (context) {
              final focused = Focus.of(context).hasFocus;
              return SizedBox(
                width: 6,
                child: Center(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    key: focused
                        ? const ValueKey('chat-resize-focused')
                        : const ValueKey('chat-resize-grip'),
                    width: focused ? 3 : 1,
                    height: focused ? 28 : double.infinity,
                    decoration: BoxDecoration(
                      color: focused ? colors.ring : colors.border,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class NarrowChatIntent extends Intent {
  const NarrowChatIntent();
}

class WidenChatIntent extends Intent {
  const WidenChatIntent();
}

class ChatVisibilityButton extends StatelessWidget {
  const ChatVisibilityButton(
      {super.key, required this.collapsed, required this.onPressed});
  final bool collapsed;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final label = collapsed ? 'Show chat' : 'Hide chat';
    return Semantics(
      label: label,
      button: true,
      child: Tooltip(
        alignment: Alignment.bottomCenter,
        anchorAlignment: Alignment.topCenter,
        tooltip: (_) => TooltipContainer(child: Text(label)),
        child: IconButton.ghost(
          key: const ValueKey('chat-visibility'),
          size: ButtonSize.small,
          onPressed: onPressed,
          icon: Icon(
              collapsed
                  ? LucideIcons.panelRightOpen
                  : LucideIcons.panelRightClose,
              size: 18),
        ),
      ),
    );
  }
}
