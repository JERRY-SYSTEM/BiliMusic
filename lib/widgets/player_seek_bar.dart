import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../utils/format.dart';

/// Playback position slider with elapsed/remaining readouts.
///
/// The drag position is owned here: while the thumb is held, the slider
/// shows the dragged value instead of the live stream position, then seeks
/// on release. [isActive] false disables seeking entirely (seeking a track
/// that is not the one playing is meaningless).
class PlayerSeekBar extends StatefulWidget {
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;

  /// Duration to use before the streamed duration is known; pass 1.0 when
  /// the track has none of its own so the slider stays well-formed.
  final double fallbackSeconds;
  final bool isActive;
  final ValueChanged<Duration> onSeek;

  const PlayerSeekBar({
    super.key,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.fallbackSeconds,
    required this.isActive,
    required this.onSeek,
  });

  @override
  State<PlayerSeekBar> createState() => _PlayerSeekBarState();
}

class _PlayerSeekBarState extends State<PlayerSeekBar> {
  double? _dragValue;

  @override
  Widget build(BuildContext context) {
    const timeStyle = TextStyle(
      color: AppColors.textMuted,
      fontSize: 12,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return AnimatedBuilder(
      animation:
          Listenable.merge([widget.durationNotifier, widget.positionNotifier]),
      builder: (context, _) {
        final streamed = widget.durationNotifier.value.inSeconds.toDouble();
        final double maxSec =
            widget.isActive && streamed > 0 ? streamed : widget.fallbackSeconds;
        final double posSec = widget.isActive
            ? (_dragValue ??
                    widget.positionNotifier.value.inSeconds.toDouble())
                .clamp(0.0, maxSec)
            : 0.0;
        var remaining = Duration(seconds: (maxSec - posSec).round());
        if (remaining < Duration.zero) remaining = Duration.zero;

        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 4,
                activeTrackColor: AppColors.accent,
                thumbColor: AppColors.accent,
                overlayColor: AppColors.accent22,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
                overlayShape:
                    const RoundSliderOverlayShape(overlayRadius: 14),
                disabledActiveTrackColor: AppColors.hairlineStrong,
                disabledInactiveTrackColor: AppColors.hairline,
                disabledThumbColor: AppColors.textFaint,
              ),
              child: Slider(
                value: posSec,
                max: maxSec,
                label: formatDuration(Duration(seconds: posSec.round())),
                onChanged: widget.isActive
                    ? (v) => setState(() => _dragValue = v)
                    : null,
                onChangeStart: (v) => setState(() => _dragValue = v),
                onChangeEnd: (v) {
                  Haptics.light();
                  widget.onSeek(Duration(seconds: v.toInt()));
                  setState(() => _dragValue = null);
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(formatDuration(Duration(seconds: posSec.round())),
                      style: timeStyle),
                  Text('-${formatDuration(remaining)}', style: timeStyle),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
