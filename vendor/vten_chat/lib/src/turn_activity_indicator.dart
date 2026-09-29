// Adapted from vten lib/widgets/vten/features/chat/widgets/turn_activity_indicator.dart
// Source SHA cc497919140469d58c71849f44210e35c3206766
// Focused diff: busy is a host flag. Riverpod session providers are not copied.

import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'animated_collapse.dart';
import 'dot_matrix_loader.dart';

/// Turn-level activity indicator docked just above the composer: a dot-matrix
/// scanner shown while the active session's agent turn is running. The
/// running state lives in this one place instead of next to every tool call.
class TurnActivityIndicator extends StatelessWidget {
  const TurnActivityIndicator({super.key, required this.busy});

  static const indicatorKey = ValueKey('vten-turn-activity-indicator');

  final bool busy;

  @override
  Widget build(BuildContext context) {
    return AnimatedCollapse(
      expanded: busy,
      child: const Padding(
        key: indicatorKey,
        padding: EdgeInsets.only(left: 6, bottom: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [DotMatrixLoader(size: 16, columns: 5, rows: 4)],
        ),
      ),
    );
  }
}
