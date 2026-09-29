import 'package:flutter/semantics.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart';

import 'tab_agent_state.dart';

/// Icon-only tab-strip mark. The agent keeps running on its own tab.
class TabAgentBadge extends StatelessWidget {
  final TabAgentState job;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onOpen;

  const TabAgentBadge({
    super.key,
    required this.job,
    required this.onPause,
    required this.onStop,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = job.isRunning ? scheme.primary : scheme.mutedForeground;
    return Tooltip(
      alignment: Alignment.bottomCenter,
      anchorAlignment: Alignment.topCenter,
      tooltip: (_) => TooltipContainer(child: Text(job.tooltip)),
      child: Semantics(
        button: true,
        label: job.tooltip,
        value: job.shortLabel,
        onTap: onOpen,
        customSemanticsActions: {
          if (job.isRunning)
            const CustomSemanticsAction(label: 'Pause'): onPause,
          if (job.isRunning) const CustomSemanticsAction(label: 'Stop'): onStop,
        },
        child: GhostButton(
          key: ValueKey('tab-agent-${job.collectionId}'),
          onPressed: onOpen,
          density: ButtonDensity.compact,
          child: SizedBox(
            width: 24,
            height: 40,
            child: Icon(LucideIcons.bot, size: 12, color: color),
          ),
        ),
      ),
    );
  }
}

/// Slim fact row under the address bar while this tab's job is inspected.
class AgentTabStatusBar extends StatelessWidget {
  final TabAgentState job;
  final VoidCallback onPause;
  final VoidCallback onStop;
  final VoidCallback onOpen;

  const AgentTabStatusBar({
    super.key,
    required this.job,
    required this.onPause,
    required this.onStop,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = job.isRunning ? scheme.primary : scheme.mutedForeground;
    final muted = TextStyle(fontSize: 12, color: scheme.mutedForeground);
    return Tooltip(
      alignment: Alignment.bottomCenter,
      anchorAlignment: Alignment.topCenter,
      tooltip: (_) => TooltipContainer(child: Text(job.tooltip)),
      child: SizedBox(
        key: ValueKey('tab-agent-bar-${job.collectionId}'),
        height: 32,
        child: Row(
          children: [
            Icon(LucideIcons.bot, size: 14, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                job.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: scheme.foreground),
              ),
            ),
            Text('${job.collected} saved', style: muted),
            const SizedBox(width: 8),
            Text(formatAgentElapsed(job.elapsedMs), style: muted),
            if (job.isRunning) ...[
              _action('tab-agent-pause-${job.collectionId}', LucideIcons.pause,
                  'Pause', onPause),
              _action('tab-agent-stop-${job.collectionId}', LucideIcons.square,
                  'Stop', onStop),
            ],
            _action('tab-agent-details-${job.collectionId}', LucideIcons.list,
                'Details', onOpen),
          ],
        ),
      ),
    );
  }

  Widget _action(String id, IconData icon, String tip, VoidCallback onPressed) {
    return Tooltip(
      alignment: Alignment.bottomCenter,
      anchorAlignment: Alignment.topCenter,
      tooltip: (_) => TooltipContainer(child: Text(tip)),
      child: IconButton.ghost(
        key: ValueKey(id),
        onPressed: onPressed,
        size: ButtonSize.small,
        icon: Icon(icon, size: 14),
      ),
    );
  }
}
