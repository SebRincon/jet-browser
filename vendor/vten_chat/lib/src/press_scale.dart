import 'package:flutter/widgets.dart';

/// Press feedback shared by the interactive chat rows (1code grammar): the
/// child scales down to [scale] while pressed and eases back to 1.0 on
/// release or cancel.
///
/// The feedback is purely visual: [onTap] fires immediately on tap-up (no
/// extra pumps needed in tests) and the hit target keeps its full layout
/// size — only the paint transform shrinks. The [GestureDetector] sits
/// outside the [AnimatedScale] with [HitTestBehavior.opaque], so it can
/// replace a bare `GestureDetector` one-for-one.
///
/// Composes with hover handling: place it inside or outside an existing
/// [MouseRegion] — PressScale never consumes pointer enter/exit events.
class PressScale extends StatefulWidget {
  const PressScale({
    super.key,
    required this.child,
    this.onTap,
    this.scale = 0.97,
    this.duration = const Duration(milliseconds: 120),
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback? onTap;

  /// Target scale while pressed.
  final double scale;

  /// Duration of the ease-out transition in each direction.
  final Duration duration;

  /// When false the row neither scales nor handles taps (it still occupies
  /// the same hit-test surface so taps don't fall through).
  final bool enabled;

  @override
  State<PressScale> createState() => _PressScaleState();
}

class _PressScaleState extends State<PressScale> {
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed == value) return;
    setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: enabled ? (_) => _setPressed(true) : null,
      onTapUp: enabled ? (_) => _setPressed(false) : null,
      onTapCancel: enabled ? () => _setPressed(false) : null,
      onTap: enabled ? widget.onTap : null,
      child: AnimatedScale(
        scale: (enabled && _pressed) ? widget.scale : 1.0,
        duration: widget.duration,
        curve: Curves.easeOut,
        child: widget.child,
      ),
    );
  }
}
