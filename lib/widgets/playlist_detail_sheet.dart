import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import '../services/database_service.dart';
import '../services/download_manager.dart';
import 'add_local_tracks_sheet.dart';
import 'empty_state.dart';
import 'track_row.dart';
import 'marquee_text.dart';
import 'mini_player.dart';
import 'track_options_menu.dart';
import 'cached_cover_image.dart';
import 'track_download_button.dart';
import '../utils/snack.dart';

class PlaylistDetailSheet extends StatefulWidget {
  final Playlist playlist;
  final TrackAction onSelectTrack;
  final TrackAction? onPlayOnly;
  final void Function(List<Track> tracks, {bool shuffle})? onPlayCollection;
  final VoidCallback? onPlaylistUpdated;
  final VoidCallback? onClose;

  const PlaylistDetailSheet({
    super.key,
    required this.playlist,
    required this.onSelectTrack,
    this.onPlayOnly,
    this.onPlayCollection,
    this.onPlaylistUpdated,
    this.onClose,
  });

  static Future<void> show(
    BuildContext context, {
    required Playlist playlist,
    required TrackAction onSelectTrack,
    TrackAction? onPlayOnly,
    void Function(List<Track> tracks, {bool shuffle})? onPlayCollection,
    VoidCallback? onPlaylistUpdated,
    VoidCallback? onClose,
  }) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      barrierColor: Colors.black38,
      isScrollControlled: true,
      builder: (context) => PlaylistDetailSheet(
        playlist: playlist,
        onSelectTrack: onSelectTrack,
        onPlayOnly: onPlayOnly,
        onPlayCollection: onPlayCollection,
        onPlaylistUpdated: onPlaylistUpdated,
        onClose: onClose ?? () => Navigator.pop(context),
      ),
    );
  }

  @override
  State<PlaylistDetailSheet> createState() => _PlaylistDetailSheetState();
}

class _PlaylistDetailSheetState extends State<PlaylistDetailSheet> {
  late Playlist _currentPlaylist;
  StreamSubscription<void>? _dlSub;
  StreamSubscription<void>? _libSub;
  bool _isEditMode = false;
  final Set<String> _selectedTrackIds = {};

  /// Playback queue for this view: the playlist's tracks minus any still
  /// downloading (not yet playable).
  List<Track> get _playableQueue => _currentPlaylist.tracks
      .where((t) => !DownloadManager.instance.isDownloading(t.id))
      .toList();
  Set<String> _dlIds = {};

  @override
  void initState() {
    super.initState();
    _currentPlaylist = _detached(widget.playlist);
    _dlIds =
        DownloadManager.instance.activeTasks.map((t) => t.track.id).toSet();
    // Metadata can be edited from the now-playing page stacked on top of this
    // sheet; without this the sheet kept rendering the pre-edit title.
    _libSub = DatabaseService.libraryUpdateStream.listen((_) => _refresh());
    _dlSub = DownloadManager.instance.updates.listen((_) {
      final ids =
          DownloadManager.instance.activeTasks.map((t) => t.track.id).toSet();
      if (!setEquals(ids, _dlIds)) {
        _dlIds = ids;
        if (mounted) setState(() {});
      }
    });
  }

  @override
  void dispose() {
    _dlSub?.cancel();
    _libSub?.cancel();
    super.dispose();
  }

  /// A copy of [pl] whose track list is detached from the database's live
  /// list. Optimistic edits (reorder, remove) mutate this private copy only;
  /// the store methods own the real mutation and persist. Sharing the store's
  /// list meant an optimistic reorder ran twice — once here, once in the store
  /// — corrupting the order and leaving the UI and disk disagreeing.
  Playlist _detached(Playlist pl) => Playlist(
        id: pl.id,
        name: pl.name,
        coverUrl: pl.coverUrl,
        tracks: pl.tracks,
      );

  Future<void> _refresh() async {
    // 本地 is a virtual playlist with no database row, so it is rebuilt from
    // the download library rather than looked up by id.
    final Playlist updated;
    if (_isVirtualDownloads) {
      updated = Playlist(
        id: _currentPlaylist.id,
        name: _currentPlaylist.name,
        tracks: await DatabaseService.getDownloadedTracks(),
      );
    } else {
      final playlists = await DatabaseService.getPlaylists();
      updated = _detached(playlists.firstWhere(
        (p) => p.id == _currentPlaylist.id,
        orElse: () => _currentPlaylist,
      ));
    }
    if (mounted) setState(() => _currentPlaylist = updated);
    widget.onPlaylistUpdated?.call();
  }

  @override
  Widget build(BuildContext context) {
    final isFav = _currentPlaylist.id == Playlist.favoritesId;
    final dockedPlayerHeight = MiniPlayer.totalHeight(context);

    return GestureDetector(
      onVerticalDragEnd: (details) {
        if ((details.primaryVelocity ?? 0) > 320) {
          Haptics.selection();
          if (widget.onClose != null) {
            widget.onClose!();
          } else {
            Navigator.pop(context);
          }
        }
      },
      child: Container(
        margin: widget.onClose != null
            ? EdgeInsets.zero
            : EdgeInsets.only(bottom: dockedPlayerHeight),
        height: MediaQuery.of(context).size.height * 0.76,
        decoration: const BoxDecoration(
          color: AppColors.surfaceDeep,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: AppColors.black50,
              blurRadius: 24,
              offset: Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          children: [
            // Drag Handle & Top Bar
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  if (_isEditMode)
                    TextButton(
                      onPressed: () {
                        setState(() {
                          if (_selectedTrackIds.length ==
                              _currentPlaylist.tracks.length) {
                            _selectedTrackIds.clear();
                          } else {
                            _selectedTrackIds.addAll(
                                _currentPlaylist.tracks.map((t) => t.id));
                          }
                        });
                      },
                      child: Text(
                        _selectedTrackIds.length ==
                                _currentPlaylist.tracks.length
                            ? '取消全选'
                            : '全选',
                        style: const TextStyle(
                            color: AppColors.accent, fontSize: 14),
                      ),
                    )
                  else
                    IconButton(
                      icon: const Icon(Icons.keyboard_arrow_down_rounded,
                          color: AppColors.textSecondary, size: 28),
                      tooltip: '收起',
                      onPressed:
                          widget.onClose ?? () => Navigator.pop(context),
                    ),
                  Expanded(
                    child: Center(
                      child: Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: AppColors.textFaint,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _isEditMode ? Icons.done_rounded : Icons.edit_outlined,
                      color: _isEditMode
                          ? AppColors.accent
                          : AppColors.textSecondary,
                      size: 22,
                    ),
                    tooltip: _isEditMode ? '完成' : '编辑',
                    onPressed: () {
                      Haptics.light();
                      setState(() {
                        _isEditMode = !_isEditMode;
                        _selectedTrackIds.clear();
                      });
                    },
                  ),
                ],
              ),
            ),

            // Header
            Padding(
              padding: const EdgeInsets.only(left: 20, right: 16),
              child: Row(
                children: [
                  _headerArtwork(isFav),
                  const SizedBox(width: 16),
                  Expanded(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onDoubleTap:
                          !_isVirtualDownloads ? _editPlaylistName : null,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _currentPlaylist.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: AppColors.textPrimary,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '${_currentPlaylist.tracks.length} 首',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppColors.textMuted, fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  ),
                  if (!_isVirtualDownloads && !_isFavorites && !_isEditMode) ...[
                    IconButton(
                      icon: const Icon(Icons.image_outlined,
                          color: AppColors.textSecondary, size: 22),
                      tooltip: '更换封面',
                      onPressed: _pickCover,
                    ),
                    IconButton(
                      icon: const Icon(Icons.add_rounded,
                          color: AppColors.textSecondary, size: 24),
                      tooltip: '添加本地曲目',
                      onPressed: _openAddLocalTracksSheet,
                    ),
                  ],
                ],
              ),
            ),

            const SizedBox(height: 16),

            if (_currentPlaylist.tracks.isNotEmpty && !_isEditMode)
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: ElevatedButton.icon(
                  onPressed: (_playableQueue.isEmpty ||
                          widget.onPlayCollection == null)
                      ? null
                      : () {
                          Haptics.medium();
                          widget.onPlayCollection?.call(_playableQueue,
                              shuffle: true);
                        },
                  icon: const Icon(Icons.shuffle_rounded, size: 22),
                  label: const Text('随机播放',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.bold)),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppColors.accent,
                    foregroundColor: AppColors.textPrimary,
                    minimumSize: const Size.fromHeight(44),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14)),
                  ),
                ),
              ),

            const SizedBox(height: 8),

            // Track List
            Expanded(
              child: _currentPlaylist.tracks.isEmpty
                  ? const Center(
                      child: EmptyState(
                        icon: Icons.library_music_rounded,
                        title: '暂无曲目',
                      ),
                    )
                  : ReorderableListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 20, vertical: 8),
                      itemCount: _currentPlaylist.tracks.length,
                      buildDefaultDragHandles: false,
                      onReorderItem: _onReorder,
                      proxyDecorator: (child, index, animation) => Material(
                        color: Colors.transparent,
                        child: Opacity(opacity: 0.9, child: child),
                      ),
                      itemBuilder: (context, index) {
                        final track = _currentPlaylist.tracks[index];
                        final rowContent = _trackRow(track, index);

                        if (_isEditMode) {
                          return Container(
                            key: ValueKey('e_${track.id}'),
                            child: rowContent,
                          );
                        }

                        return ReorderableDelayedDragStartListener(
                          key: ValueKey(track.id),
                          index: index,
                          child: Dismissible(
                            key: ValueKey('d_${track.id}'),
                            direction: DismissDirection.endToStart,
                            background: _removeBackground(),
                            confirmDismiss: (_) => _confirmRemove(track),
                            onDismissed: (_) => _removeTrack(track),
                            child: rowContent,
                          ),
                        );
                      },
                    ),
            ),

            if (_isEditMode)
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
                decoration: const BoxDecoration(
                  color: AppColors.backgroundElevated,
                  border: Border(top: BorderSide(color: AppColors.hairline)),
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: TextButton.icon(
                        icon: const Icon(Icons.playlist_add_rounded,
                            color: AppColors.textPrimary),
                        label: Text(
                          '加入歌单 (${_selectedTrackIds.length})',
                          style: TextStyle(
                            color: _selectedTrackIds.isEmpty
                                ? AppColors.textFaint
                                : AppColors.textPrimary,
                          ),
                        ),
                        onPressed: _selectedTrackIds.isEmpty
                            ? null
                            : () async {
                                final selected = _currentPlaylist.tracks
                                    .where((t) =>
                                        _selectedTrackIds.contains(t.id))
                                    .toList();
                                await TrackOptionsMenu
                                    .showAddToPlaylistForTracks(
                                  context,
                                  selected,
                                  onTrackChanged: () {
                                    setState(() {
                                      _isEditMode = false;
                                      _selectedTrackIds.clear();
                                    });
                                    _refresh();
                                  },
                                );
                              },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: TextButton.icon(
                        icon: const Icon(Icons.delete_outline_rounded,
                            color: AppColors.danger),
                        label: Text(
                          '删除 (${_selectedTrackIds.length})',
                          style: TextStyle(
                            color: _selectedTrackIds.isEmpty
                                ? AppColors.textFaint
                                : AppColors.danger,
                          ),
                        ),
                        onPressed: _selectedTrackIds.isEmpty
                            ? null
                            : _deleteSelectedTracks,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One track row; selection/download state is read live here so
  /// edit mode and normal mode share a single definition.
  Widget _trackRow(Track track, int index) {
    final isDownloading =
        DownloadManager.instance.isDownloading(track.id);
    final isSelected = _selectedTrackIds.contains(track.id);

    return Padding(
      padding:
          const EdgeInsets.only(bottom: TrackRow.gap),
      child: TrackRow(
        onTap: _isEditMode
            ? () {
                setState(() {
                  if (isSelected) {
                    _selectedTrackIds.remove(track.id);
                  } else {
                    _selectedTrackIds.add(track.id);
                  }
                });
              }
            : (isDownloading
                ? null
                : () => widget.onSelectTrack(track,
                    queue: _playableQueue)),
        child: Row(
          children: [
            if (_isEditMode) ...[
              Icon(
                isSelected
                    ? Icons.check_circle_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: isSelected
                    ? AppColors.accent
                    : AppColors.textFaint,
                size: 22,
              ),
              const SizedBox(width: 12),
            ],
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: CachedCoverImage(
                url: track.coverUrl,
                width: 48,
                height: 48,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  RepaintBoundary(
                    child: MarqueeText(
                      text: track.title,
                      phase: (index % 5) / 5,
                      style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          height: 1.3),
                    ),
                  ),
                  Text(
                    track.uploader,
                    style: const TextStyle(
                        color: AppColors.textMuted,
                        fontSize: 12),
                  ),
                ],
              ),
            ),
            if (!_isEditMode) ...[
              const SizedBox(width: 8),
              TrackDownloadButton(
                track: track,
                size: 24,
                onPlay: () {
                  if (widget.onPlayOnly != null) {
                    widget.onPlayOnly!(track,
                        queue: _playableQueue);
                  } else {
                    widget.onSelectTrack(track,
                        queue: _playableQueue);
                  }
                },
              ),
              IconButton(
                icon: const Icon(Icons.add,
                    color: AppColors.textSecondary,
                    size: 22),
                tooltip: '添加至歌单',
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                    minWidth: 40, minHeight: 40),
                onPressed: () {
                  TrackOptionsMenu.showAddToPlaylist(
                      context, track,
                      onTrackChanged: _refresh);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The red "remove" affordance revealed by swiping a row left.
  Widget _removeBackground() {
    return Container(
      margin: const EdgeInsets.only(bottom: TrackRow.gap),
      alignment: Alignment.centerRight,
      padding: const EdgeInsets.only(right: 20),
      decoration: BoxDecoration(
        color: AppColors.danger.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        _isVirtualDownloads
            ? Icons.delete_outline_rounded
            : Icons.playlist_remove_rounded,
        color: AppColors.danger,
      ),
    );
  }

  bool get _isVirtualDownloads => _currentPlaylist.id == 'downloaded';
  bool get _isFavorites => _currentPlaylist.id == Playlist.favoritesId;

  /// The playlist's artwork. 本地 is rebuilt from
  /// the download library on every refresh and has no row to store a cover on,
  /// so it keeps the default badge.
  Widget _headerArtwork(bool isFav) {
    final cover = _currentPlaylist.coverUrl;
    final List<Color> gradient;
    final IconData icon;
    if (_isVirtualDownloads) {
      gradient = [AppColors.success, const Color(0xFF1B8A4B)];
      icon = Icons.download_rounded;
    } else if (isFav) {
      gradient = [AppColors.accent, const Color(0xFFFF5252)];
      icon = Icons.favorite;
    } else {
      gradient = [AppColors.surfaceNeutral, AppColors.surfaceNeutralDeep];
      icon = Icons.queue_music;
    }
    return SizedBox(
      width: 72,
      height: 72,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: cover != null && cover.isNotEmpty && !_isVirtualDownloads
            ? CachedCoverImage(url: cover, width: 72, height: 72)
            : DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(colors: gradient),
                ),
                child: Center(
                  child: Icon(icon, color: AppColors.textPrimary, size: 36),
                ),
              ),
      ),
    );
  }

  Future<void> _pickCover() async {
    Haptics.light();
    try {
      final image =
          await ImagePicker().pickImage(source: ImageSource.gallery);
      if (image == null) return;
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/bilibeat_covers');
      if (!await dir.exists()) await dir.create(recursive: true);
      final ext = image.path.split('.').last;
      final saved = File(
          '${dir.path}/playlist_${_currentPlaylist.id}_'
          '${DateTime.now().millisecondsSinceEpoch}.$ext');
      await File(image.path).copy(saved.path);
      await DatabaseService.setPlaylistCover(_currentPlaylist.id, saved.path);
      await _refresh();
    } catch (e) {
      debugPrint('Playlist cover pick failed: $e');
    }
  }

  Future<void> _openAddLocalTracksSheet() async {
    Haptics.light();
    final downloaded = await DatabaseService.getDownloadedTracks();
    if (!mounted) return;

    if (downloaded.isEmpty) {
      showAppSnackBar(
        ScaffoldMessenger.of(context),
        message: '暂无本地已下载曲目，去搜索下载音乐吧',
        backgroundColor: AppColors.backgroundElevated,
      );
      return;
    }

    await AddLocalTracksSheet.show(
      context,
      downloaded: downloaded,
      existingIds: _currentPlaylist.tracks.map((t) => t.id).toSet(),
      playlistId: _currentPlaylist.id,
      onAdded: _refresh,
    );
  }

  Future<void> _deleteSelectedTracks() async {
    if (_selectedTrackIds.isEmpty) return;
    final count = _selectedTrackIds.length;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title: Text(_isVirtualDownloads ? '删除本地音频' : '从歌单移除',
            style: const TextStyle(color: AppColors.textPrimary)),
        content: Text(
          _isVirtualDownloads
              ? '确定要彻底删除选中的 $count 首本地音频吗？（本地文件将被删除）'
              : '确定要将选中的 $count 首曲目从「${_currentPlaylist.name}」中移除吗？',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(_isVirtualDownloads ? '彻底删除' : '移除',
                style: const TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final selected = _currentPlaylist.tracks
        .where((t) => _selectedTrackIds.contains(t.id))
        .toList();

    if (_isVirtualDownloads) {
      for (final track in selected) {
        await DatabaseService.removeDownloadedTrack(track);
      }
    } else {
      await DatabaseService.removeTracksFromPlaylist(
          _currentPlaylist.id, selected.map((t) => t.id).toList());
    }

    // The sheet may have been dismissed while the confirm dialog or the
    // delete loop was up.
    if (!mounted) return;
    setState(() {
      _selectedTrackIds.clear();
      _isEditMode = false;
    });
    await _refresh();
  }

  Future<void> _editPlaylistName() async {
    Haptics.light();
    final controller = TextEditingController(text: _currentPlaylist.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title: const Text('重命名歌单', style: TextStyle(color: AppColors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
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
            child: const Text('保存', style: TextStyle(color: AppColors.accent)),
            onPressed: () => Navigator.pop(dCtx, controller.text),
          ),
        ],
      ),
    );
    controller.dispose();

    if (newName != null && newName.trim().isNotEmpty && newName.trim() != _currentPlaylist.name) {
      await DatabaseService.renamePlaylist(_currentPlaylist.id, newName.trim());
      await _refresh();
    }
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    Haptics.selection();
    // Reorder locally first so the list does not flash back to the old order
    // while the store round-trips.
    setState(() {
      final tracks = _currentPlaylist.tracks;
      final track = tracks.removeAt(oldIndex);
      tracks.insert(newIndex.clamp(0, tracks.length), track);
    });
    if (_isVirtualDownloads) {
      await DatabaseService.reorderDownloaded(oldIndex, newIndex);
    } else {
      await DatabaseService.reorderPlaylist(
          _currentPlaylist.id, oldIndex, newIndex);
    }
    widget.onPlaylistUpdated?.call();
  }

  Future<bool> _confirmRemove(Track track) async {
    // Removing from a playlist is trivially reversible; deleting the audio
    // itself is not, so only that path asks.
    if (!_isVirtualDownloads) return true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title: const Text('删除本地音频',
            style: TextStyle(color: AppColors.textPrimary)),
        content: const Text('将删除本地音频，可重新下载。',
            style: TextStyle(color: AppColors.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  Future<void> _removeTrack(Track track) async {
    setState(() => _currentPlaylist.tracks.removeWhere((t) => t.id == track.id));
    if (_isVirtualDownloads) {
      await DatabaseService.removeDownloadedTrack(track);
    } else {
      await DatabaseService.removeTrackFromPlaylist(
          _currentPlaylist.id, track.id);
    }
    widget.onPlaylistUpdated?.call();
  }
}
