import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../models/track.dart';
import '../models/playlist.dart';
import '../services/database_service.dart';
import '../services/audio_download_service.dart';
import '../services/download_manager.dart';
import '../utils/snack.dart';
import 'cached_cover_image.dart';

class TrackOptionsMenu extends StatefulWidget {
  final Track track;
  final VoidCallback? onTrackChanged;

  const TrackOptionsMenu({
    super.key,
    required this.track,
    this.onTrackChanged,
  });

  static Future<void> show(BuildContext context, Track track, {VoidCallback? onTrackChanged}) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => TrackOptionsMenu(
        track: track,
        onTrackChanged: onTrackChanged,
      ),
    );
  }

  static Future<void> showAddToPlaylist(BuildContext context, Track track, {VoidCallback? onTrackChanged}) {
    return showAddToPlaylistForTracks(context, [track], onTrackChanged: onTrackChanged);
  }

  static Future<void> showAddToPlaylistForTracks(BuildContext context, List<Track> tracks, {VoidCallback? onTrackChanged}) async {
    if (tracks.isEmpty) return;
    final List<Playlist> playlists = await DatabaseService.getPlaylists();

    if (!context.mounted) return;
    final parentMessenger = ScaffoldMessenger.of(context);

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.backgroundElevated,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return StatefulBuilder(
          builder: (dialogCtx, setDialogState) {
            return Container(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        tracks.length == 1 ? '加入歌单' : '批量加入歌单 (${tracks.length} 首)',
                        style: const TextStyle(color: AppColors.textPrimary, fontSize: 18, fontWeight: FontWeight.bold),
                      ),
                      TextButton.icon(
                        icon: const Icon(Icons.add, color: AppColors.accent, size: 20),
                        label: const Text('新建歌单', style: TextStyle(color: AppColors.accent)),
                        onPressed: () async {
                          final controller = TextEditingController();
                          final newPlName = await showDialog<String>(
                            context: ctx,
                            builder: (dCtx) => AlertDialog(
                              backgroundColor: AppColors.backgroundElevated,
                              title: const Text('新建歌单', style: TextStyle(color: AppColors.textPrimary)),
                              content: TextField(
                                controller: controller,
                                style: const TextStyle(color: AppColors.textPrimary),
                                decoration: const InputDecoration(
                                  hintText: '歌单名称',
                                  hintStyle: TextStyle(color: AppColors.textFaint),
                                ),
                              ),
                              actions: [
                                TextButton(
                                  child: const Text('取消'),
                                  onPressed: () => Navigator.pop(dCtx),
                                ),
                                TextButton(
                                  child: const Text('创建', style: TextStyle(color: AppColors.accent)),
                                  onPressed: () => Navigator.pop(dCtx, controller.text),
                                ),
                              ],
                            ),
                          );

                          controller.dispose();

                          if (newPlName != null && newPlName.trim().isNotEmpty) {
                            final created = await DatabaseService.createPlaylist(newPlName);
                            // One persist for the whole batch, not a full-file
                            // rewrite per track.
                            await DatabaseService.addTracksToPlaylist(created.id, tracks);
                            for (final t in tracks) {
                              DownloadManager.instance.startDownload(t);
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            onTrackChanged?.call();
                            showAppSnackBar(parentMessenger,
                                message: '已加入「${created.name}」');
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 280),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: playlists.length,
                      itemBuilder: (context, index) {
                        final pl = playlists[index];
                        return ListTile(
                          leading: Icon(
                            pl.id == Playlist.favoritesId ? Icons.favorite : Icons.queue_music,
                            color: pl.id == Playlist.favoritesId ? AppColors.accent : AppColors.textSecondary,
                          ),
                          title: Text(pl.name, style: const TextStyle(color: AppColors.textPrimary)),
                          subtitle: Text('${pl.tracks.length} 首', style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                          onTap: () async {
                            await DatabaseService.addTracksToPlaylist(pl.id, tracks);
                            for (final t in tracks) {
                              DownloadManager.instance.startDownload(t);
                            }
                            if (ctx.mounted) Navigator.pop(ctx);
                            onTrackChanged?.call();
                            showAppSnackBar(parentMessenger,
                                message: '已加入「${pl.name}」');
                          },
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  State<TrackOptionsMenu> createState() => _TrackOptionsMenuState();
}

class _TrackOptionsMenuState extends State<TrackOptionsMenu> {
  bool _isFav = false;
  bool _isDownloaded = false;

  @override
  void initState() {
    super.initState();
    _checkStatus();
  }

  Future<void> _checkStatus() async {
    final fav = await DatabaseService.isFavorite(widget.track.id);
    final isDown = await AudioDownloadService.isDownloaded(widget.track);

    if (mounted) {
      setState(() {
        _isFav = fav;
        _isDownloaded = isDown;
      });
    }
  }

  Future<void> _handleDownload() async {
    final messenger = ScaffoldMessenger.of(context);
    final track = widget.track;
    Navigator.pop(context);

    // Already local: offer to reclaim the space instead of downloading twice.
    if (_isDownloaded) {
      await DatabaseService.removeDownloadedTrack(track);
      widget.onTrackChanged?.call();
      showAppSnackBar(messenger,
          message: '已删除本地音频',
          backgroundColor: AppColors.backgroundElevated);
      return;
    }

    // Not awaited: startDownload only returns when the file is on disk, so
    // awaiting it delayed the "download started" toast until the download had
    // already finished — minutes later, on a slow connection.
    unawaited(DownloadManager.instance.startDownload(track));
    widget.onTrackChanged?.call();

    showAppSnackBar(messenger, message: '已开始下载');
  }

  Future<void> _handleFavorite() async {
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    final nowFav = await DatabaseService.toggleFavorite(widget.track);
    if (nowFav && !_isDownloaded) {
      DownloadManager.instance.startDownload(widget.track);
    }
    widget.onTrackChanged?.call();

    final msg = nowFav
        ? '已收藏'
        : '已取消收藏';
    showAppSnackBar(
      messenger,
      message: msg,
      icon: nowFav ? Icons.favorite : Icons.favorite_border,
      backgroundColor: AppColors.backgroundElevated,
    );
  }

  Future<void> _handleAddToPlaylist() async {
    Navigator.pop(context);
    if (!mounted) return;
    TrackOptionsMenu.showAddToPlaylist(context, widget.track, onTrackChanged: widget.onTrackChanged);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppColors.backgroundElevated,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.only(top: 12, bottom: 24, left: 16, right: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Drag Handle
          Container(
            width: 36,
            height: 5,
            decoration: BoxDecoration(
              color: AppColors.textFaint,
              borderRadius: BorderRadius.circular(3),
            ),
          ),

          const SizedBox(height: 16),

          // Header: Track Thumbnail, FULL Untruncated Title, Uploader
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: CachedCoverImage(
                  url: widget.track.coverUrl,
                  width: 60,
                  height: 60,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // FULL Untruncated Track Title
                    Text(
                      widget.track.title,
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.track.uploader,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),

          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Divider(color: AppColors.white12, height: 1),
          ),

          // Action Items
          ListTile(
            leading: Icon(
              _isDownloaded ? Icons.delete_outline_rounded : Icons.download_rounded,
              color: _isDownloaded ? AppColors.danger : AppColors.textPrimary,
            ),
            title: Text(
              _isDownloaded ? '删除本地音频' : '下载到本地',
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
            ),
            onTap: _handleDownload,
          ),

          ListTile(
            leading: const Icon(Icons.playlist_add, color: AppColors.textPrimary),
            title: const Text(
              '加入歌单',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
            ),
            onTap: _handleAddToPlaylist,
          ),

          ListTile(
            leading: Icon(
              _isFav ? Icons.favorite : Icons.favorite_border,
              color: _isFav ? AppColors.accent : AppColors.textPrimary,
            ),
            title: Text(
              _isFav ? '取消收藏' : '添加至收藏',
              style: const TextStyle(color: AppColors.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
            ),
            onTap: _handleFavorite,
          ),
        ],
      ),
    );
  }
}
