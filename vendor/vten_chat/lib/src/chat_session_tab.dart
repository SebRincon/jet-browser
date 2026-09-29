// Adapted from vten vten_ide/lib/app/editor/tab_views/chat_session_tab.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: MessageList and EnhancedPromptInput are supplied by the host.
// TurnActivityIndicator from VtenAgentChatView sits in the same 8px inset.

import 'dart:math' as math;

import 'package:flutter/material.dart' as material;
import 'package:shadcn_flutter/shadcn_flutter.dart';

class ChatSessionTab extends material.StatelessWidget {
  const ChatSessionTab({
    super.key,
    required this.messageList,
    required this.prompt,
    this.activity,
    this.onUserInteracted,
  });

  final Widget messageList;
  final Widget prompt;
  final Widget? activity;
  final void Function()? onUserInteracted;

  @override
  material.Widget build(material.BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final height = constraints.maxHeight;
      final composerCap = height.isFinite ? math.min(220.0, height * 0.46) : 220.0;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: messageList),
          const Divider(height: 1),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: math.max(48, composerCap)),
            child: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: material.Listener(
                  behavior: material.HitTestBehavior.translucent,
                  onPointerDown: (_) => onUserInteracted?.call(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (activity != null) activity!,
                      prompt,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}
