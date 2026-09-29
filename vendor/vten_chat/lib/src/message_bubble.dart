// Adapted from vten lib/widgets/vten/features/chat/widgets/message_bubble.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: the assistant column keeps source spacing, markdown slot,
// collapsed steps, planning shimmer, and copy footer. IDE tool dispatch,
// checkpoints, and role labels are not rendered.

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'assistant_message_footer.dart';
import 'collapsible_steps_widget.dart';
import 'text_shimmer.dart';
import 'tool_call_action_wrapper.dart';
import 'user_message_bubble.dart';

const vtenPlanningWords = [
  'Crafting',
  'Whirring',
  'Imagining',
  'Cooking',
  'Sussing',
  'Unravelling',
  'Creating',
  'Spinning',
  'Computing',
  'Synthesizing',
  'Manifesting',
];

class MessageBubble extends StatelessWidget {
  const MessageBubble.user({
    super.key,
    required this.text,
  })  : user = true,
        markdown = null,
        copyText = '',
        streaming = false,
        activity = const [],
        collapsedSteps = const [],
        stepsSummary = null,
        planningSeed = '';

  const MessageBubble.assistant({
    super.key,
    this.markdown,
    this.copyText = '',
    this.streaming = false,
    this.activity = const [],
    this.collapsedSteps = const [],
    this.stepsSummary,
    this.planningSeed = '',
  })  : user = false,
        text = '';

  final bool user;
  final String text;
  final Widget? markdown;
  final String copyText;
  final bool streaming;
  final List<Widget> activity;
  final List<Widget> collapsedSteps;
  final String? stepsSummary;
  final String planningSeed;

  @override
  Widget build(BuildContext context) {
    if (user) {
      return Align(
        alignment: Alignment.centerRight,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: UserMessageBubble(text: text),
        ),
      );
    }
    final theme = Theme.of(context);
    final children = <Widget>[
      ...activity,
      if (markdown != null) markdown!,
      if (collapsedSteps.isNotEmpty)
        CollapsibleStepsWidget(
          stepsCount: collapsedSteps.length,
          summary: stepsSummary,
          children: collapsedSteps,
        ),
    ];
    if (children.isEmpty && streaming) {
      final word = vtenPlanningWords[
          planningSeed.hashCode.abs() % vtenPlanningWords.length];
      children.add(
        Align(
          alignment: Alignment.centerLeft,
          child: TextShimmer(
            text: '$word…',
            style: theme.typography.p.copyWith(
              fontSize: 12,
              color: theme.colorScheme.mutedForeground,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: AnimatedSize(
        duration: streaming
            ? const Duration(milliseconds: 1)
            : const Duration(milliseconds: 220),
        curve: Curves.easeInOutCubic,
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < children.length; i++)
              Padding(
                padding: EdgeInsets.only(
                  bottom: children[i] is ToolCallActionWrapper &&
                          i + 1 < children.length &&
                          children[i + 1] is ToolCallActionWrapper
                      ? 0
                      : 8,
                ),
                child: children[i],
              ),
            if (!streaming && copyText.trim().isNotEmpty)
              AssistantMessageFooter(copyText: copyText),
          ],
        ),
      ),
    );
  }
}
