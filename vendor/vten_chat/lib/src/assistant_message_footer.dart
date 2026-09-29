// Adapted from vten lib/widgets/vten/features/chat/widgets/message_bubble.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: none in the painted footer. Semantics label added for the
// icon-only control.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'chrome_icon_button.dart';

/// 24px footer under a finished assistant message: a muted copy button that
/// copies the message's text parts and cross-fades to a check for 2 seconds.
class AssistantMessageFooter extends StatefulWidget {
  const AssistantMessageFooter({super.key, required this.copyText});

  final String copyText;

  @override
  State<AssistantMessageFooter> createState() => _AssistantMessageFooterState();
}

class _AssistantMessageFooterState extends State<AssistantMessageFooter> {
  bool _hovered = false;
  bool _pressed = false;
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.copyText));
    if (!mounted) return;
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 24,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            button: true,
            label: 'Copy message',
            child: ChromeTooltip(
              message: 'Copy message',
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: GestureDetector(
                  onTapDown: (_) => setState(() => _pressed = true),
                  onTapUp: (_) => setState(() => _pressed = false),
                  onTapCancel: () => setState(() => _pressed = false),
                  onTap: _copy,
                  child: AnimatedScale(
                    scale: _pressed ? 0.97 : 1.0,
                    duration: const Duration(milliseconds: 120),
                    curve: Curves.easeOut,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      curve: Curves.easeOut,
                      padding: const EdgeInsets.all(5),
                      decoration: BoxDecoration(
                        color: _hovered
                            ? theme.colorScheme.accent
                            : theme.colorScheme.accent.withValues(alpha: 0),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 160),
                        switchInCurve: Curves.easeOut,
                        switchOutCurve: Curves.easeOut,
                        child: Icon(
                          _copied ? LucideIcons.check : LucideIcons.copy,
                          key: ValueKey<bool>(_copied),
                          size: 14,
                          color: theme.colorScheme.mutedForeground,
                        ),
                      ),
                    ),
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
