import 'package:flutter/material.dart';

/// A single-line text that scrolls continuously when — and only when — it is
/// too wide for the space it was given, with soft fade-outs at both edges.
///
/// The motion is unbroken: constant velocity, no dwell at either end, and a
/// second copy of the text trailing exactly one cycle behind so the wrap point
/// is invisible. Text that fits is drawn statically and costs nothing.
///
/// ## Why this is written the way it is
///
/// The previous marquee measured its text in a post-frame callback and called
/// `setState`, which changed the widget's own size *after* layout had already
/// completed. Inside a `Column` (mini player / now-playing panel) that pushed
/// the siblings around and, in the worst case, collapsed the whole panel. This
/// implementation is structurally incapable of doing that:
///
///  * The height is derived synchronously from a [TextPainter] during `build`,
///    so the widget reports a stable, correct size on the very first layout
///    pass and never changes it afterwards.
///  * The overflow amount is computed in the same synchronous pass from the
///    incoming [BoxConstraints] — no measurement round-trip.
///  * The scroll itself is a [Transform.translate] driven by an
///    [AnimationController]. A transform is a paint-time effect: it can never
///    feed back into layout, so the parent `Column` is never disturbed.
///  * The controller is only ever started/stopped from a post-frame callback,
///    and starting it does not call `setState`.
class MarqueeText extends StatefulWidget {
  final String text;
  final TextStyle style;

  /// Scroll speed in logical pixels per second.
  final double velocity;

  /// Blank space between the end of the text and the start of its repeat.
  final double gap;

  /// Starting offset within the cycle, 0..1. Rows in a list pass different
  /// phases so a screenful of titles does not slide in lockstep.
  final double phase;

  /// Alignment used when the text *fits* and no scrolling is needed.
  final TextAlign textAlign;

  /// Soft alpha fade at the leading/trailing edges while scrolling.
  final bool fade;

  const MarqueeText({
    super.key,
    required this.text,
    required this.style,
    this.velocity = 26,
    this.gap = 44,
    this.phase = 0.0,
    this.textAlign = TextAlign.start,
    this.fade = true,
  });

  @override
  State<MarqueeText> createState() => _MarqueeTextState();
}

class _MarqueeTextState extends State<MarqueeText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 1),
  );

  // Cached measurement so we do not re-run a TextPainter on every build.
  String? _measuredText;
  TextStyle? _measuredStyle;
  double _measuredScale = 1.0;
  Size _measuredSize = Size.zero;

  // Cycle geometry, recomputed in build; read by the animation callback.
  double _travel = 0.0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// The style the child [Text]s will actually be painted with.
  ///
  /// [Text] merges the ambient [DefaultTextStyle] into an inheriting style, so
  /// measuring `widget.style` alone measured a *different* font from the one on
  /// screen — the app's theme sets a family and letter spacing that the callers'
  /// styles do not. The cycle length was therefore off by the difference, and
  /// since the trailing copy is positioned by layout while the scroll is
  /// positioned by the measurement, the repeat landed a few pixels away from
  /// where the original started: a visible hitch at the wrap. Resolving the
  /// style once here and using it for *both* keeps them exact.
  TextStyle _effectiveStyle(BuildContext context) {
    if (!widget.style.inherit) return widget.style;
    return DefaultTextStyle.of(context).style.merge(widget.style);
  }

  Size _measure(BuildContext context, TextStyle style) {
    final scale = MediaQuery.textScalerOf(context).scale(1.0);
    if (_measuredText == widget.text &&
        _measuredStyle == style &&
        _measuredScale == scale) {
      return _measuredSize;
    }
    final painter = TextPainter(
      text: TextSpan(text: widget.text, style: style),
      maxLines: 1,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
    )..layout();
    _measuredText = widget.text;
    _measuredStyle = style;
    _measuredScale = scale;
    _measuredSize = painter.size;
    painter.dispose();
    return _measuredSize;
  }

  /// Reconciles the controller with the geometry computed during build.
  /// Deferred to after the frame so we never mutate an animation mid-layout;
  /// it touches no layout-affecting state, so it cannot shift the parent.
  void _syncController({required bool shouldRun, required Duration cycle}) {
    if (!mounted) return;
    if (!shouldRun) {
      if (_controller.isAnimating) _controller.stop();
      if (_controller.value != 0) _controller.value = 0;
      return;
    }
    if (_controller.duration != cycle) {
      _controller.duration = cycle;
      _controller.stop();
      _controller.value = 0;
    }
    if (!_controller.isAnimating) _controller.repeat();
  }

  @override
  Widget build(BuildContext context) {
    final style = _effectiveStyle(context);
    final textSize = _measure(context, style);
    // A deterministic single-line height: the widget's size is settled before
    // the first paint and never changes.
    final lineHeight = textSize.height;

    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;

        // Unbounded width (e.g. inside an unconstrained Row) — a marquee has no
        // meaning here, and measuring against infinity would be wrong.
        if (!maxWidth.isFinite) {
          return Text(
            widget.text,
            maxLines: 1,
            softWrap: false,
            style: style,
            textAlign: widget.textAlign,
          );
        }

        // Only overflowing text scrolls; text that fits is simply drawn.
        final overflows = textSize.width > maxWidth + 0.5;
        if (!overflows) {
          _scheduleSync(shouldRun: false, cycle: Duration.zero);
          return SizedBox(
            width: maxWidth,
            height: lineHeight,
            child: Text(
              widget.text,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: style,
              textAlign: widget.textAlign,
            ),
          );
        }

        // One cycle scrolls the text plus the gap, so the repeat slides in
        // seamlessly behind it and the motion never visibly restarts.
        _travel = textSize.width + widget.gap;
        final cycle = Duration(
            milliseconds:
                (_travel / widget.velocity * 1000).round().clamp(1, 600000));

        _scheduleSync(shouldRun: true, cycle: cycle);

        Widget marquee = ClipRect(
          child: OverflowBox(
            alignment: Alignment.centerLeft,
            maxWidth: double.infinity,
            child: AnimatedBuilder(
              animation: _controller,
              builder: (context, child) {
                // Continuous: constant velocity, no dwell, wrapping seamlessly
                // because the second copy is exactly one `travel` behind.
                final progress = (_controller.value + widget.phase) % 1.0;
                return Transform.translate(
                  offset: Offset(-progress * _travel, 0),
                  child: child,
                );
              },
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.text,
                      maxLines: 1, softWrap: false, style: style),
                  SizedBox(width: widget.gap),
                  Text(widget.text,
                      maxLines: 1, softWrap: false, style: style),
                ],
              ),
            ),
          ),
        );

        if (widget.fade) {
          marquee = ShaderMask(
            blendMode: BlendMode.dstIn,
            shaderCallback: (rect) {
              final fadeStop = (12.0 / rect.width).clamp(0.0, 0.25);
              return LinearGradient(
                colors: const [
                  Color(0x00FFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0xFFFFFFFF),
                  Color(0x00FFFFFF),
                ],
                stops: [0.0, fadeStop, 1.0 - fadeStop, 1.0],
              ).createShader(rect);
            },
            child: marquee,
          );
        }

        return SizedBox(width: maxWidth, height: lineHeight, child: marquee);
      },
    );
  }

  bool? _syncedRun;
  Duration? _syncedCycle;

  /// Only queues a post-frame callback when the desired animation state has
  /// actually changed. The mini player rebuilds on every play/pause and track
  /// change; scheduling a callback each time was pure churn.
  void _scheduleSync({required bool shouldRun, required Duration cycle}) {
    if (_syncedRun == shouldRun && _syncedCycle == cycle) return;
    _syncedRun = shouldRun;
    _syncedCycle = cycle;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncController(shouldRun: shouldRun, cycle: cycle);
    });
  }
}
