import 'package:shadcn_flutter/shadcn_flutter.dart';

/// In-pane disclosure used by the trace view. Chat rows use the vendored
/// vten tool and steps widgets instead.
class ActivityDisclosure extends StatefulWidget {
  const ActivityDisclosure(
      {super.key,
      required this.title,
      required this.icon,
      required this.child,
      this.meta,
      this.error,
      this.detail});
  final String title;
  final IconData icon;
  final String? meta;
  final String? detail;
  final String? error;
  final Widget child;
  @override
  State<ActivityDisclosure> createState() => _ActivityDisclosureState();
}

class _ActivityDisclosureState extends State<ActivityDisclosure> {
  bool expanded = false;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      GhostButton(
          alignment: Alignment.centerLeft,
          size: ButtonSize.small,
          density: ButtonDensity.dense,
          onPressed: () => setState(() => expanded = !expanded),
          child: Row(children: [
            Icon(widget.error == null ? widget.icon : LucideIcons.circleAlert,
                size: 14,
                color: widget.error == null
                    ? colors.mutedForeground
                    : colors.destructive),
            const SizedBox(width: 7),
            Expanded(
                child: Text(widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: colors.mutedForeground))),
            if (widget.meta != null)
              Text(widget.meta!,
                  style: TextStyle(
                      fontSize: 12,
                      color: widget.error == null
                          ? colors.mutedForeground
                          : colors.destructive)),
            const SizedBox(width: 6),
            Icon(expanded ? LucideIcons.chevronDown : LucideIcons.chevronRight,
                size: 13, color: colors.mutedForeground),
          ])),
      if (widget.error != null)
        Padding(
            padding: const EdgeInsets.fromLTRB(24, 2, 6, 6),
            child: Text(widget.error!,
                maxLines: expanded ? null : 2,
                overflow: expanded ? null : TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 12, height: 1.5, color: colors.destructive))),
      if (!expanded && widget.detail != null)
        Padding(
            padding: const EdgeInsets.only(left: 24, bottom: 4),
            child: Text(widget.detail!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: colors.mutedForeground))),
      AnimatedSize(
          duration: const Duration(milliseconds: 180),
          alignment: Alignment.topLeft,
          child: expanded
              ? Container(
                  margin: const EdgeInsets.only(left: 10, top: 5, bottom: 8),
                  padding: const EdgeInsets.only(left: 14, top: 4, bottom: 4),
                  decoration: BoxDecoration(
                      border: Border(left: BorderSide(color: colors.border))),
                  child: widget.child)
              : const SizedBox.shrink()),
    ]);
  }
}
