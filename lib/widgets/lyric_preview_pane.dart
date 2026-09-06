import 'package:flutter/material.dart';
import '../models/lyric_line.dart';
import '../theme/app_theme.dart';
import 'synced_lyrics_view.dart';

/// State C of the lyrics tab: synced preview of a candidate lyric result
/// with tap-to-calibrate and 应用. The pane is stateless; the dialog's State
/// owns the offset/calibration values and every transition out of it.
class LyricPreviewPane extends StatelessWidget {
  final LyricsResult result;

  /// Title shown in the header when the result carries none of its own.
  final String fallbackTitle;
  final ValueNotifier<Duration> positionNotifier;
  final double offset;
  final bool calibrating;
  final VoidCallback onBack;
  final VoidCallback onEditLrc;
  final ValueChanged<double> onCalibrateTap;
  final VoidCallback onStartCalibrating;
  final VoidCallback onApply;

  const LyricPreviewPane({
    super.key,
    required this.result,
    required this.fallbackTitle,
    required this.positionNotifier,
    required this.offset,
    required this.calibrating,
    required this.onBack,
    required this.onEditLrc,
    required this.onCalibrateTap,
    required this.onStartCalibrating,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Header
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
              onPressed: onBack,
            ),
            Expanded(
              child: Text(
                result.songTitle ?? fallbackTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined,
                  color: AppColors.textMuted, size: 20),
              tooltip: '编辑 LRC',
              onPressed: onEditLrc,
            ),
          ],
        ),
        const SizedBox(height: 6),

        // Synced preview
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Container(
              color: Colors.black26,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: SyncedLyricsView(
                lines: result.lines,
                positionNotifier: positionNotifier,
                offset: offset,
                calibrating: calibrating,
                onCalibrateTap: onCalibrateTap,
                autoFollow: false,
              ),
            ),
          ),
        ),
        const SizedBox(height: 10),

        // 校准 / 应用 — calibrating: single 完成 button that applies;
        // otherwise: 校准 + 应用.
        Row(
          children: [
            Expanded(
              child: SizedBox(
                height: 44,
                child: OutlinedButton(
                  onPressed: calibrating ? onApply : onStartCalibrating,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: calibrating ? AppColors.accent : AppColors.textMuted,
                    side: BorderSide(color: calibrating ? AppColors.accent30 : AppColors.white24),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: Text(calibrating ? '完成' : '校准',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                ),
              ),
            ),
            if (!calibrating) ...[
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    onPressed: onApply,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.accent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('应用',
                        style: TextStyle(
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
