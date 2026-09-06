import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// The surface a song sits on in a list.
///
/// Deliberately *not* a [GlassCard]. A card is a container for something you
/// look at as an object — the search field, a playlist tile, the quick-access
/// pair. A song in a list is not an object, it is a line: giving each one a
/// border, a sheen and its own margin turned every list into a stack of boxes
/// that read as heavy long before the eye got to the titles.
///
/// So a row here has no chrome of its own. The artwork is the only thing with a
/// shape, rows sit close together, and the surface only appears on touch — a
/// rounded highlight under the finger. Glass is kept for the surfaces that
/// genuinely are cards.
class TrackRow extends StatelessWidget {
  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Row-to-row breathing space. Small on purpose: the gap is what makes a
  /// list read as a list rather than as separate cards.
  static const double gap = 2.0;

  const TrackRow({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 7),
          child: child,
        ),
      ),
    );
  }
}
