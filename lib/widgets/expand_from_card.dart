import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'mini_player.dart';

/// Route transition in which the docked card *becomes* the page.
///
/// The page is laid out at full size from the first frame and only its
/// *clip* is animated — from the card's rectangle out to the whole screen,
/// with the corner radius unrolling as it goes. Nothing inside the page
/// relayouts during the morph (a scale/size animation would relayout the
/// lyrics list and the seek bar 60 times a second), and the reverse is the
/// same motion run backwards, so closing folds the page back down onto the
/// card it came from.
///
/// The card's surface colour is cross-faded into the page's background and the
/// page's content fades in slightly behind the growth, which is what stops the
/// first frames from looking like a screenshot stretched out of a bar.
class ExpandFromCard extends StatefulWidget {
  final Animation<double> animation;

  /// The docked card's rectangle in global coordinates.
  final Rect from;
  final Widget child;

  const ExpandFromCard({
    super.key,
    required this.animation,
    required this.from,
    required this.child,
  });

  @override
  State<ExpandFromCard> createState() => _ExpandFromCardState();
}

class _ExpandFromCardState extends State<ExpandFromCard> {
  late CurvedAnimation _curve = _build();

  CurvedAnimation _build() => CurvedAnimation(
        parent: widget.animation,
        curve: AppMotion.standard,
        reverseCurve: AppMotion.standardReverse,
      );

  @override
  void didUpdateWidget(covariant ExpandFromCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _curve.dispose();
      _curve = _build();
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final screen = Offset.zero & size;

    return AnimatedBuilder(
      animation: _curve,
      child: widget.child,
      builder: (context, child) {
        final t = _curve.value;
        // Settled: hand the page through untouched, with no clip, no opacity
        // layer and no stack in the way.
        if (t >= 1.0) return child!;

        final rect = Rect.lerp(widget.from, screen, t)!;
        // Starts as the card's shape — top corners only, since it is seated on
        // the bottom edge — and unrolls to the square-cornered page.
        final radius =
            BorderRadius.lerp(MiniPlayer.cardRadius, BorderRadius.zero, t)!;
        // The content trails the growth a little; by ~60% of the way it is
        // fully there.
        final fade = ((t - 0.1) / 0.5).clamp(0.0, 1.0);

        return Stack(
          children: [
            Positioned.fromRect(
              rect: rect,
              child: ClipRRect(
                borderRadius: radius,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // One surface throughout: the card and the page are the
                    // same near-black, so there is nothing to cross-fade.
                    const ColoredBox(color: AppColors.background),
                    // Full-size page, clipped by the box above it. Anchored to
                    // the bottom so the transport controls — the part the card
                    // itself shows — stay put while the rest unfolds upwards.
                    OverflowBox(
                      alignment: Alignment.bottomCenter,
                      minWidth: size.width,
                      maxWidth: size.width,
                      minHeight: size.height,
                      maxHeight: size.height,
                      child: Opacity(opacity: fade, child: child),
                    ),
                  ],
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
