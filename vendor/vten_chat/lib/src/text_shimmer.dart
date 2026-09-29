import 'package:flutter/widgets.dart';
import 'package:shadcn_flutter/shadcn_flutter.dart' show Theme;

/// 1code-style pending-text treatment: a bright highlight sweeps across the
/// text from left to right on a muted base color (1.2s linear, repeating).
/// The highlight width scales with the text length, matching the original's
/// per-character spread. Use on pending tool titles instead of a spinner.
class TextShimmer extends StatefulWidget {
  const TextShimmer({
    super.key,
    required this.text,
    required this.style,
    this.duration = const Duration(milliseconds: 1200),
    this.baseColor,
    this.highlightColor,
  });

  final String text;
  final TextStyle style;
  final Duration duration;
  final Color? baseColor;
  final Color? highlightColor;

  @override
  State<TextShimmer> createState() => _TextShimmerState();
}

class _TextShimmerState extends State<TextShimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = widget.baseColor ?? theme.colorScheme.mutedForeground;
    final highlight = widget.highlightColor ?? theme.colorScheme.foreground;
    // The original scales the highlight to ~2px per character; clamp to a
    // sane band so very short/long titles still read well.
    final spreadPx = (widget.text.length * 2).clamp(16, 120).toDouble();

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (bounds) {
            // Paint the gradient on a 2.5x-wide rect translated across the
            // text so the highlight band fully enters and exits the visible
            // area; stops stay inside [0, 1].
            final bandWidth = bounds.width * 2.5;
            final t = _controller.value;
            final left =
                bounds.left - bandWidth * 0.62 + bounds.width * 1.6 * t;
            final spread = (spreadPx / bandWidth).clamp(0.02, 0.2);
            return LinearGradient(
              colors: [base, highlight, base],
              stops: [0.5 - spread, 0.5, 0.5 + spread],
            ).createShader(
              Rect.fromLTWH(left, bounds.top, bandWidth, bounds.height),
            );
          },
          child: Text(
            widget.text,
            style: widget.style.copyWith(color: const Color(0xFFFFFFFF)),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}
