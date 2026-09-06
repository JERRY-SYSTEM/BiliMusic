import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import '../models/track.dart';
import 'cached_cover_image.dart';
import 'marquee_text.dart';

/// The docked player — a compact edition of the now-playing page rather than a
/// separate control bar.
///
/// It is deliberately built from the same parts as the now-playing page,
/// because tapping it *becomes* that page: the card's rounded surface grows
/// into the page, so the two must share a visual language or the morph reads as
/// a jump cut. The artwork uses the album-art corner radius, the surface is the
/// same near-black, the seek bar is the same track and the same accent, and the
/// primary control is the same gradient circle at bar scale. Nothing here is
/// "the card's own" version of anything.
///
/// Still no `BackdropFilter`: real-time blur over the whole page cost a full
/// GPU layer pass every frame and was the root of the Android foreground
/// erasure bug. A tuned opaque surface reads just as rich and costs nothing.
class MiniPlayer extends StatelessWidget {
  final Track? currentTrack;
  final bool isPlaying;
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback? onPrevious;
  final VoidCallback onTap;

  /// Seek, from dragging the card's own progress bar.
  final ValueChanged<Duration>? onSeek;

  const MiniPlayer({
    super.key,
    required this.currentTrack,
    required this.isPlaying,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.onPlayPause,
    required this.onNext,
    this.onPrevious,
    required this.onTap,
    this.onSeek,
  });

  /// Height of the card's contents, above the home-indicator inset.
  static const double contentHeight = 82.0;

  static const double _artSize = 54.0;

  /// Height of the strip along the bottom that seeks. The bar drawn inside it
  /// is 3pt; the rest is the touch target a 3pt line cannot be.
  static const double _seekStrip = 22.0;

  /// The album art's radius, so the card looks like the page folded down.
  static const BorderRadius cardRadius =
      BorderRadius.vertical(top: Radius.circular(AppRadius.xl));

  /// Space between the controls and the very bottom of the screen: the
  /// home-indicator inset, or a small margin on devices without one. It is
  /// *inside* the card — the card itself is flush to the edge.
  static double bottomInset(BuildContext context) {
    final inset = MediaQuery.of(context).padding.bottom;
    return inset > 0 ? inset : 6;
  }

  /// Total space the docked player occupies — the single source of truth for
  /// every layout that has to stop above it.
  static double totalHeight(BuildContext context) =>
      contentHeight + bottomInset(context);

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      // Cast upwards: a shadow below a bottom-seated bar is off-screen. This
      // one lifts the card off the list scrolling under it.
      decoration: const BoxDecoration(
        borderRadius: cardRadius,
        boxShadow: [
          BoxShadow(
            color: AppColors.black55,
            blurRadius: 26,
            spreadRadius: -2,
            offset: Offset(0, -6),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: cardRadius,
        child: DecoratedBox(
          decoration: const BoxDecoration(
            // The page's background, not a lighter "elevated" surface. The
            // card is the page folded down; a different shade makes it a
            // different object, and the morph turns into a colour change.
            color: AppColors.background,
            border: Border(top: BorderSide(color: AppColors.hairline)),
            borderRadius: cardRadius,
          ),
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomInset(context)),
            child: SizedBox(
              height: contentHeight,
              child: currentTrack == null ? _emptyState() : _activePlayer(),
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    return const Padding(
      padding: EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _EmptyArt(),
          SizedBox(width: 12),
          Expanded(
            child: Text('选一首歌开始播放',
                style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    letterSpacing: -0.1)),
          ),
        ],
      ),
    );
  }

  Widget _activePlayer() {
    final track = currentTrack!;
    return GestureDetector(
      onTap: onTap,
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) < -180) {
          Haptics.selection();
          onTap();
        }
      },
      onHorizontalDragEnd: (details) {
        final v = details.primaryVelocity ?? 0;
        if (v < -220) {
          Haptics.selection();
          onNext();
        } else if (v > 220 && onPrevious != null) {
          Haptics.selection();
          onPrevious!();
        }
      },
      // The seek bar overlays the bottom of the row rather than sitting in a
      // lane below it. A lane pushes the row upwards, and then the artwork is
      // visibly off the card's own centre line — which is the first thing the
      // eye checks on a bar this size.
      child: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 8, _seekStrip - 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: CachedCoverImage(
                    url: track.coverUrl,
                    width: _artSize,
                    height: _artSize,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: AppMotion.fast,
                    switchInCurve: AppMotion.standard,
                    switchOutCurve: AppMotion.standardReverse,
                    transitionBuilder: (child, animation) =>
                        FadeTransition(opacity: animation, child: child),
                    child: Column(
                      key: ValueKey<String>(track.id),
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        MarqueeText(
                          text: track.title,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 15,
                            height: 1.3,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.25,
                          ),
                        ),
                        const SizedBox(height: 2),
                        MarqueeText(
                          text: track.uploader,
                          phase: 0.35,
                          style: const TextStyle(
                            color: AppColors.textMuted,
                            fontSize: 12.5,
                            height: 1.35,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // Same shape and place as the page's primary control, so the
                // eye can track it across the morph — but quiet. A filled pink
                // disc is right at 68pt in the middle of the player; shrunk
                // onto a bar it was the loudest thing on the screen and fought
                // the artwork it sits next to.
                _playButton(),
                _iconButton(
                  Icons.skip_next_rounded,
                  onPressed: () {
                    Haptics.selection();
                    onNext();
                  },
                ),
              ],
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: _seekStrip,
            child: _MiniSeekBar(
              positionNotifier: positionNotifier,
              durationNotifier: durationNotifier,
              onSeek: onSeek,
            ),
          ),
        ],
      ),
    );
  }

  Widget _playButton() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.light();
        onPlayPause();
      },
      child: SizedBox(
        width: 50,
        height: 50,
        child: Center(
          child: Container(
            width: 40,
            height: 40,
            // The page's primary control at bar scale: same gradient, same
            // glow, same white glyph. It is the one thing the eye tracks
            // across the morph, so it has to be the same thing.
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              gradient: AppColors.primaryGradient,
              boxShadow: [
                BoxShadow(
                    color: AppColors.accent30,
                    blurRadius: 14,
                    offset: Offset(0, 4)),
              ],
            ),
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 160),
              transitionBuilder: (child, animation) =>
                  ScaleTransition(scale: animation, child: child),
              child: Icon(
                isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey<bool>(isPlaying),
                color: AppColors.textPrimary,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _iconButton(IconData icon, {required VoidCallback onPressed}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onPressed,
      child: SizedBox(
        width: 44,
        height: 46,
        child: Center(
          child: Icon(icon, color: AppColors.textSecondary, size: 26),
        ),
      ),
    );
  }
}

/// The page's seek bar, folded down: same track, same accent, and draggable.
///
/// Stateful because a drag has to show where the finger is rather than where
/// playback still is — otherwise the bar fights the thumb all the way across.
class _MiniSeekBar extends StatefulWidget {
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;
  final ValueChanged<Duration>? onSeek;

  const _MiniSeekBar({
    required this.positionNotifier,
    required this.durationNotifier,
    this.onSeek,
  });

  @override
  State<_MiniSeekBar> createState() => _MiniSeekBarState();
}

class _MiniSeekBarState extends State<_MiniSeekBar> {
  double? _dragFraction;

  static const double _hPad = 16.0;

  double _fractionFor(double dx, double width) {
    final usable = width - _hPad * 2;
    if (usable <= 0) return 0.0;
    return ((dx - _hPad) / usable).clamp(0.0, 1.0);
  }

  void _commit(double fraction) {
    final total = widget.durationNotifier.value;
    if (total > Duration.zero && widget.onSeek != null) {
      widget.onSeek!(total * fraction);
    }
  }

  @override
  Widget build(BuildContext context) {
    final seekable = widget.onSeek != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          // Opaque and horizontal: this strip claims the sideways drag inside
          // its own bounds, so seeking here never reaches the card's
          // swipe-to-change-track gesture behind it.
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: seekable
              ? (d) {
                  Haptics.selection();
                  setState(() =>
                      _dragFraction = _fractionFor(d.localPosition.dx, width));
                }
              : null,
          onHorizontalDragUpdate: seekable
              ? (d) => setState(() =>
                  _dragFraction = _fractionFor(d.localPosition.dx, width))
              : null,
          onHorizontalDragEnd: seekable
              ? (_) {
                  final f = _dragFraction;
                  if (f != null) {
                    Haptics.light();
                    _commit(f);
                  }
                  setState(() => _dragFraction = null);
                }
              : null,
          onHorizontalDragCancel:
              seekable ? () => setState(() => _dragFraction = null) : null,
          onTapUp: seekable
              ? (d) {
                  Haptics.light();
                  _commit(_fractionFor(d.localPosition.dx, width));
                }
              : null,
          child: AnimatedBuilder(
            animation: Listenable.merge(
                [widget.positionNotifier, widget.durationNotifier]),
            builder: (context, _) {
              final total = widget.durationNotifier.value.inMilliseconds;
              final played = total > 0
                  ? (widget.positionNotifier.value.inMilliseconds / total)
                      .clamp(0.0, 1.0)
                  : 0.0;
              final fraction = _dragFraction ?? played;
              final dragging = _dragFraction != null;

              return Padding(
                padding: const EdgeInsets.symmetric(horizontal: _hPad),
                child: Center(
                  child: SizedBox(
                    // Full width, explicitly. Left to shrink-wrap, the fill
                    // sized the track and the whole bar grew outwards from the
                    // centre of the card.
                    width: double.infinity,
                    height: dragging ? 5 : 3,
                    child: Stack(
                      fit: StackFit.expand,
                      clipBehavior: Clip.none,
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(3),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              const ColoredBox(
                                  color: AppColors.hairlineStrong),
                              Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  widthFactor: fraction,
                                  heightFactor: 1,
                                  child: const ColoredBox(
                                      color: AppColors.accent),
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (dragging)
                          Align(
                            alignment: Alignment(fraction * 2 - 1, 0),
                            child: Container(
                              width: 11,
                              height: 11,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Placeholder artwork for the "nothing playing" state, in the same slot the
/// cover occupies so the bar does not change shape when playback starts.
class _EmptyArt extends StatelessWidget {
  const _EmptyArt();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: MiniPlayer._artSize,
      height: MiniPlayer._artSize,
      decoration: BoxDecoration(
        color: AppColors.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: const Icon(Icons.music_note_rounded,
          color: AppColors.textFaint, size: 22),
    );
  }
}
