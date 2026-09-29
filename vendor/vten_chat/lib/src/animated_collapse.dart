import 'package:flutter/widgets.dart';

/// Smoothly grows/shrinks (and fades) its [child] when [expanded] toggles.
///
/// The child is removed from the tree only once the collapse animation
/// completes, and is mounted again the moment an expand starts — so finders
/// and semantics match the visual state at rest. The initial state renders
/// without animation (history loads do not ripple).
class AnimatedCollapse extends StatefulWidget {
  const AnimatedCollapse({
    super.key,
    required this.expanded,
    required this.child,
    this.duration = const Duration(milliseconds: 220),
    this.curve = Curves.easeInOutCubic,
  });

  final bool expanded;
  final Widget child;
  final Duration duration;
  final Curve curve;

  @override
  State<AnimatedCollapse> createState() => _AnimatedCollapseState();
}

class _AnimatedCollapseState extends State<AnimatedCollapse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: widget.expanded ? 1.0 : 0.0,
  );
  late final CurvedAnimation _animation = CurvedAnimation(
    parent: _controller,
    curve: widget.curve,
  );

  @override
  void didUpdateWidget(covariant AnimatedCollapse oldWidget) {
    super.didUpdateWidget(oldWidget);
    _controller.duration = widget.duration;
    if (oldWidget.expanded != widget.expanded) {
      if (widget.expanded) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    }
  }

  @override
  void dispose() {
    _animation.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      child: widget.child,
      builder: (context, child) {
        if (_controller.isDismissed) return const SizedBox.shrink();
        if (_controller.isCompleted) return child!;
        return ClipRect(
          child: Align(
            alignment: Alignment.topLeft,
            heightFactor: _animation.value,
            child: Opacity(opacity: _animation.value, child: child),
          ),
        );
      },
    );
  }
}

/// A chevron that rotates between collapsed (pointing right) and expanded
/// (pointing down) instead of swapping glyphs.
class AnimatedChevron extends StatelessWidget {
  const AnimatedChevron({
    super.key,
    required this.expanded,
    required this.icon,
    this.duration = const Duration(milliseconds: 180),
  });

  final bool expanded;
  final Widget icon;
  final Duration duration;

  @override
  Widget build(BuildContext context) {
    return AnimatedRotation(
      turns: expanded ? 0.25 : 0.0,
      duration: duration,
      curve: Curves.easeInOutCubic,
      child: icon,
    );
  }
}
