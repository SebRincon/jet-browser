import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show Theme;

/// A miniature dot-matrix loading indicator (in the spirit of
/// lportals/dot_matrix_loader): a small grid of dots lit by a left-to-right
/// scanner sweep with a phosphor-style trailing fade. Sized to replace inline
/// spinners (defaults to 14px) and colored from the theme when no explicit
/// colors are given.
class DotMatrixLoader extends StatefulWidget {
  const DotMatrixLoader({
    super.key,
    this.size = 14,
    this.columns = 4,
    this.rows = 4,
    this.activeColor,
    this.inactiveColor,
    this.period = const Duration(milliseconds: 1100),
  });

  final double size;
  final int columns;
  final int rows;
  final Color? activeColor;
  final Color? inactiveColor;
  final Duration period;

  @override
  State<DotMatrixLoader> createState() => _DotMatrixLoaderState();
}

class _DotMatrixLoaderState extends State<DotMatrixLoader>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.period,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = widget.activeColor ?? theme.colorScheme.primary;
    final inactive =
        widget.inactiveColor ??
        theme.colorScheme.mutedForeground.withValues(alpha: 0.25);

    return RepaintBoundary(
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, _) {
            return CustomPaint(
              painter: _DotMatrixPainter(
                t: _controller.value,
                columns: widget.columns,
                rows: widget.rows,
                active: active,
                inactive: inactive,
              ),
            );
          },
        ),
      ),
    );
  }
}

class _DotMatrixPainter extends CustomPainter {
  _DotMatrixPainter({
    required this.t,
    required this.columns,
    required this.rows,
    required this.active,
    required this.inactive,
  });

  final double t;
  final int columns;
  final int rows;
  final Color active;
  final Color inactive;

  @override
  void paint(Canvas canvas, Size size) {
    final cellW = size.width / columns;
    final cellH = size.height / rows;
    final radius = math.min(cellW, cellH) * 0.32;
    final paint = Paint();

    // Scanner sweeps across the columns; let it run one column past each
    // edge so the trail fades out fully before wrapping.
    final scan = t * (columns + 2) - 1;

    for (var col = 0; col < columns; col++) {
      // Phosphor trail: full brightness at the scan column, fading behind it.
      final distance = scan - col;
      double intensity;
      if (distance < 0) {
        intensity = 0;
      } else {
        intensity = math.max(0, 1 - distance / 2.5);
      }
      final color = Color.lerp(inactive, active, intensity)!;
      paint.color = color;
      for (var row = 0; row < rows; row++) {
        canvas.drawCircle(
          Offset(cellW * (col + 0.5), cellH * (row + 0.5)),
          radius,
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotMatrixPainter oldDelegate) =>
      oldDelegate.t != t ||
      oldDelegate.active != active ||
      oldDelegate.inactive != inactive;
}
