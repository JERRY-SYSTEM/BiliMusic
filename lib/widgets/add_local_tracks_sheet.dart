import 'package:flutter/material.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import 'cached_cover_image.dart';

/// Bottom sheet for adding already-downloaded (本地) tracks to a playlist.
/// Tracks already present in the target playlist are shown disabled with a
/// 已在歌单 label. Selection is owned here; persistence and the post-add
/// refresh belong to the caller via [onAdded].
class AddLocalTracksSheet extends StatefulWidget {
  final List<Track> downloaded;
  final Set<String> existingIds;
  final String playlistId;

  /// Called after the selected tracks were written to the playlist, so the
  /// presenting screen can refresh.
  final Future<void> Function() onAdded;

  const AddLocalTracksSheet({
    super.key,
    required this.downloaded,
    required this.existingIds,
    required this.playlistId,
    required this.onAdded,
  });

  static Future<void> show(
    BuildContext context, {
    required List<Track> downloaded,
    required Set<String> existingIds,
    required String playlistId,
    required Future<void> Function() onAdded,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.backgroundElevated,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => AddLocalTracksSheet(
        downloaded: downloaded,
        existingIds: existingIds,
        playlistId: playlistId,
        onAdded: onAdded,
      ),
    );
  }

  @override
  State<AddLocalTracksSheet> createState() => _AddLocalTracksSheetState();
}

class _AddLocalTracksSheetState extends State<AddLocalTracksSheet> {
  final Set<String> _selectedIds = {};

  Future<void> _addSelected() async {
    final tracksToAdd = widget.downloaded
        .where((t) => _selectedIds.contains(t.id))
        .toList();
    // One persist for the whole batch — the per-track call rewrote the
    // entire playlists file once per selected song.
    await DatabaseService.addTracksToPlaylist(widget.playlistId, tracksToAdd);
    if (mounted) Navigator.pop(context);
    await widget.onAdded();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: MediaQuery.of(context).size.height * 0.7,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('添加本地曲目',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold)),
              TextButton(
                onPressed: _selectedIds.isEmpty ? null : _addSelected,
                child: Text('添加 (${_selectedIds.length})',
                    style: TextStyle(
                        color: _selectedIds.isEmpty
                            ? AppColors.textFaint
                            : AppColors.accent,
                        fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: ListView.builder(
              itemCount: widget.downloaded.length,
              itemBuilder: (c, idx) {
                final t = widget.downloaded[idx];
                final isAlreadyInPlaylist = widget.existingIds.contains(t.id);
                final isChecked = _selectedIds.contains(t.id);

                return ListTile(
                  enabled: !isAlreadyInPlaylist,
                  leading: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: CachedCoverImage(
                        url: t.coverUrl, width: 40, height: 40),
                  ),
                  title: Text(t.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: isAlreadyInPlaylist
                              ? AppColors.textMuted
                              : AppColors.textPrimary)),
                  subtitle: Text(t.uploader,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppColors.textMuted, fontSize: 12)),
                  trailing: isAlreadyInPlaylist
                      ? const Text('已在歌单',
                          style: TextStyle(
                              color: AppColors.textFaint, fontSize: 12))
                      : Icon(
                          isChecked
                              ? Icons.check_circle_rounded
                              : Icons.radio_button_unchecked_rounded,
                          color: isChecked
                              ? AppColors.accent
                              : AppColors.textFaint,
                        ),
                  onTap: isAlreadyInPlaylist
                      ? null
                      : () {
                          setState(() {
                            if (isChecked) {
                              _selectedIds.remove(t.id);
                            } else {
                              _selectedIds.add(t.id);
                            }
                          });
                        },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
