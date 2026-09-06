import 'package:flutter/material.dart';
import '../models/lyric_line.dart';
import '../theme/app_theme.dart';

/// One row in the lyric search results list. The body previews/calibrates;
/// the trailing icon applies directly. Editing lives on the preview page's
/// top-right button, so the row carries no edit affordance of its own.
class LyricResultRow extends StatelessWidget {
  final LyricsResult result;
  final bool isSelected;

  /// Human-readable provider name, resolved by the dialog (the pinned
  /// current row surfaces the lyrics' real origin from the cache).
  final String sourceLabel;

  /// First couple of non-empty lyric lines, for at-a-glance identification.
  final String snippet;
  final VoidCallback onPreview;
  final VoidCallback onApply;

  const LyricResultRow({
    super.key,
    required this.result,
    required this.isSelected,
    required this.sourceLabel,
    required this.snippet,
    required this.onPreview,
    required this.onApply,
  });

  @override
  Widget build(BuildContext context) {
    final isUserPasted = result.source == 'user';
    final isCurrent = result.source == 'current';

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: isCurrent
            ? AppColors.success12
            : (isUserPasted ? AppColors.accent12 : AppColors.white06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: isSelected
              ? AppColors.accent
              : (isCurrent
                  ? AppColors.success50
                  : (isUserPasted ? AppColors.accent50 : AppColors.white12)),
          width: isSelected || isUserPasted || isCurrent ? 1.5 : 1.0,
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: InkWell(
              borderRadius:
                  const BorderRadius.horizontal(left: Radius.circular(16)),
              onTap: onPreview,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title with source + line count inline on the same line —
                    // they used to take a third line of their own.
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            isCurrent
                                ? '当前歌词'
                                : (isUserPasted
                                    ? '粘贴歌词'
                                    : (result.songTitle ?? '未知歌曲')),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: isCurrent
                                  ? AppColors.success
                                  : (isUserPasted
                                      ? AppColors.pinkStart
                                      : AppColors.textPrimary),
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          sourceLabel.isEmpty
                              ? '${result.lines.length} 行'
                              : '$sourceLabel · ${result.lines.length} 行',
                          maxLines: 1,
                          style: const TextStyle(
                            color: AppColors.textFaint,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      snippet,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 12.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // Apply — the only per-row action; calibrate/edit happen in preview.
          IconButton(
            icon: Icon(
              isCurrent
                  ? Icons.check_circle
                  : (isSelected
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked),
              color: isCurrent
                  ? AppColors.success
                  : (isSelected ? AppColors.accent : AppColors.textFaint),
              size: 24,
            ),
            onPressed: isCurrent ? null : onApply,
            tooltip: isCurrent ? '当前歌词' : '应用',
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}
