import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'cached_cover_image.dart';

/// The editor's 信息 tab: cover art (tap to replace), song-title/artist
/// fields and the 智能识别 button. Pure presentation — image picking and
/// parsing live in the dialog's State and arrive here as callbacks.
class LyricEditorInfoTab extends StatelessWidget {
  final TextEditingController titleController;
  final TextEditingController artistController;
  final TextEditingController coverUrlController;
  final VoidCallback onPickCover;
  final VoidCallback onAutoParse;

  /// True while the 智能识别 DB lookup is in flight: the button shows a
  /// spinner and is disabled, because no result is displayed before the
  /// validation answer arrives.
  final bool parsing;

  const LyricEditorInfoTab({
    super.key,
    required this.titleController,
    required this.artistController,
    required this.coverUrlController,
    required this.onPickCover,
    required this.onAutoParse,
    this.parsing = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const SizedBox(height: 8),
                // Cover art — tap to change, sized to match player page
                LayoutBuilder(
                  builder: (context, constraints) {
                    final availableWidth = constraints.maxWidth;
                    final coverSize = (availableWidth * 0.62).clamp(140.0, 320.0);
                    return Center(
                      child: Stack(
                        alignment: Alignment.bottomRight,
                        children: [
                          GestureDetector(
                            onTap: onPickCover,
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(AppRadius.xl),
                              child: CachedCoverImage(
                                url: coverUrlController.text.trim(),
                                width: coverSize,
                                height: coverSize,
                              ),
                            ),
                          ),
                          GestureDetector(
                            onTap: onPickCover,
                            child: Container(
                              padding: const EdgeInsets.all(6),
                              decoration: BoxDecoration(
                                color: context.palette.backgroundElevated,
                                shape: BoxShape.circle,
                                border: Border.all(color: context.palette.hairline),
                              ),
                              child: Icon(Icons.image_outlined,
                                  color: context.palette.textSecondary, size: 18),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                _infoField(context, titleController, '歌名'),
                const SizedBox(height: 12),
                _infoField(context, artistController, '歌手 / UP主'),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  height: 44,
                  child: OutlinedButton.icon(
                    onPressed: parsing ? null : onAutoParse,
                    icon: parsing
                        ? SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: context.palette.accent),
                          )
                        : Icon(Icons.auto_awesome, color: context.palette.accent, size: 18),
                    label: Text('智能识别歌名与歌手',
                        style: TextStyle(
                            color: context.palette.accent,
                            fontSize: 14,
                            fontWeight: FontWeight.w600)),
                    style: OutlinedButton.styleFrom(
                      side: BorderSide(color: context.palette.accent30),
                      backgroundColor: context.palette.accent14,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
      ],
    );
  }

  Widget _infoField(
      BuildContext context, TextEditingController ctrl, String label) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(
                color: context.palette.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        TextField(
          controller: ctrl,
          style: TextStyle(color: context.palette.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: context.palette.surfaceCard,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
          ),
        ),
      ],
    );
  }
}
