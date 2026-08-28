import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import '../models/lyric_line.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/database_service.dart';
import '../services/audio_download_service.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import 'ambient_background.dart';
import 'cached_cover_image.dart';
import 'marquee_text.dart';
import 'progress_ring.dart';
import 'player_seek_bar.dart';
import 'synced_lyrics_view.dart';
import 'lyric_editor_dialog.dart';
import 'player_queue_sheet.dart';

/// Full-screen "now playing" surface.
class NowPlayingSheet extends StatefulWidget {
  final BiliBeatAudioHandler handler;
  final Track focusedTrack;
  final ValueNotifier<Duration> positionNotifier;
  final ValueNotifier<Duration> durationNotifier;
  final ValueNotifier<List<LyricLine>> lyricsNotifier;

  /// Set when the sheet is opened as part of "play this now". The handler has
  /// not switched track yet at that instant, so it cannot be inferred — and
  /// getting it wrong leaves the sheet stuck on one track for the whole
  /// session, never following the queue.
  final bool followHandler;
  final VoidCallback? onQueueCleared;

  const NowPlayingSheet({
    super.key,
    required this.handler,
    required this.focusedTrack,
    required this.positionNotifier,
    required this.durationNotifier,
    required this.lyricsNotifier,
    this.followHandler = false,
    this.onQueueCleared,
  });

  @override
  State<NowPlayingSheet> createState() => _NowPlayingSheetState();
}

class _NowPlayingSheetState extends State<NowPlayingSheet> {
  final List<StreamSubscription> _subs = [];

  late Track _displayTrack;
  bool _followHandler = false;
  bool _isPlaying = false;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.all;
  bool _showLyrics = false;
  bool _isFavorite = false;
  bool _isDownloaded = false;
  DownloadTask? _downloadTask;
  bool _showEditor = false;
  bool _editorLyricsTab = false;
  VoidCallback? _editorRelease;

  bool get _isActive => widget.handler.currentTrack?.id == _displayTrack.id;

  @override
  void initState() {
    super.initState();
    final h = widget.handler;
    _displayTrack = widget.focusedTrack;
    _followHandler =
        widget.followHandler || (h.currentTrack?.id == _displayTrack.id);
    _isPlaying = h.isPlaying;
    _isShuffle = h.isShuffle;
    _loopMode = h.loopMode;
    _downloadTask = _liveTaskFor(_displayTrack.id);
    _refreshTrackState();

    _subs.add(h.currentTrackStream.listen((t) {
      if (t == null || !mounted) return;
      if (_followHandler && t.id != _displayTrack.id) {
        setState(() {
          _displayTrack = t;
          // The download task follows the displayed track, or the primary
          // control stays stuck on the previous song's ring.
          _downloadTask = _liveTaskFor(t.id);
        });
        _refreshTrackState();
      } else if (t.id == _displayTrack.id) {
        setState(() => _displayTrack = t); // metadata edit
      }
    }));
    _subs.add(h.playerStateStream.listen((p) {
      if (!mounted) return;
      setState(() => _isPlaying = p);
      // Playback implies the file reached disk, and the handler downloads
      // outside DownloadManager — so re-check rather than leaving the control
      // stuck on "download" while the track plays.
      if (p && _isActive && !_isDownloaded) _refreshDownloaded();
    }));
    _subs.add(h.shuffleStream.listen((s) {
      if (mounted) setState(() => _isShuffle = s);
    }));
    _subs.add(h.loopModeStream.listen((m) {
      if (mounted) setState(() => _loopMode = m);
    }));
    _subs.add(h.queueStream.listen((_) {
      if (mounted) setState(() {});
    }));
    _subs.add(DownloadManager.instance.updates.listen((changedId) {
      // Only this sheet's track matters: progress ticks for any other
      // download arrive every 64 KiB and would rebuild the whole page for
      // nothing. Unchanged tasks (same object) are equally skippable.
      if (!mounted || changedId != _displayTrack.id) return;
      final task = _liveTaskFor(_displayTrack.id);
      final finished = _downloadTask != null && task == null;
      if (identical(task, _downloadTask)) return;
      setState(() => _downloadTask = task);
      // Only stat the filesystem when a download actually finished, not on
      // every progress tick (they arrive every 64 KiB).
      if (finished) _refreshDownloaded();
    }));
  }

  DownloadTask? _liveTaskFor(String id) => DownloadManager.instance.taskFor(id);

  @override
  void dispose() {
    _editorRelease?.call();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  /// One combined refresh so switching tracks costs a single rebuild.
  Future<void> _refreshTrackState() async {
    final track = _displayTrack;
    final results = await Future.wait([
      AudioDownloadService.isDownloaded(track),
      DatabaseService.isFavorite(track.id),
    ]);
    if (!mounted || _displayTrack.id != track.id) return;
    setState(() {
      _isDownloaded = results[0] && !DownloadManager.instance.isDownloading(track.id);
      _isFavorite = results[1];
    });
  }

  Future<void> _refreshDownloaded() async {
    final track = _displayTrack;
    final downloaded = await AudioDownloadService.isDownloaded(track);
    if (!mounted || _displayTrack.id != track.id) return;
    setState(() => _isDownloaded = downloaded);
  }

  void _startDownload() {
    Haptics.light();
    DownloadManager.instance.startDownload(_displayTrack);
    if (mounted) {
      setState(() => _downloadTask = _liveTaskFor(_displayTrack.id));
    }
  }

  void _playOrPause() {
    Haptics.light();
    if (_isActive) {
      _isPlaying ? widget.handler.pause() : widget.handler.play();
    } else {
      _followHandler = true;
      widget.handler.playTrack(_displayTrack);
    }
  }

  void _prev() {
    Haptics.selection();
    _followHandler = true;
    widget.handler.skipToPrevious();
  }

  void _next() {
    Haptics.selection();
    _followHandler = true;
    widget.handler.skipToNext();
  }

  Future<void> _handleFavorite() async {
    Haptics.light();
    final nowFav = await DatabaseService.toggleFavorite(_displayTrack);
    if (mounted) setState(() => _isFavorite = nowFav);
    if (nowFav && !_isDownloaded) _startDownload();
  }

  void _openEditor({bool lyricsTab = false}) {
    _editorRelease?.call();
    _editorRelease = widget.handler.holdAutoAdvance();
    setState(() {
      _showEditor = true;
      _editorLyricsTab = lyricsTab;
    });
  }

  void _closeEditor() {
    _editorRelease?.call();
    _editorRelease = null;
    setState(() => _showEditor = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The same backdrop as the rest of the app — the aura at the top, black
      // below — rather than a flat black page. The route morph paints its own
      // opaque surface underneath, so this stays honest during the transition.
      backgroundColor: context.palette.background,
      body: PopScope(
        canPop: !_showEditor,
        onPopInvokedWithResult: (didPop, result) {
          if (didPop) return;
          if (_showEditor) {
            Haptics.selection();
            _closeEditor();
          }
        },
        child: Stack(
          children: [
            Positioned.fill(
              child: AmbientBackground(coverUrl: _displayTrack.coverUrl),
            ),
            GestureDetector(
              // Swipe down anywhere on the chrome to dismiss, like the system sheets.
              onVerticalDragEnd: (details) {
                if ((details.primaryVelocity ?? 0) > 320) {
                  Haptics.selection();
                  if (_showEditor) {
                    _closeEditor();
                  } else {
                    Navigator.of(context).maybePop();
                  }
                }
              },
        child: SafeArea(
          minimum: const EdgeInsets.only(top: 16),
          child: Column(
            children: [
              Expanded(
                child: AnimatedSwitcher(
                  duration: AppMotion.base,
                  switchInCurve: AppMotion.standard,
                  switchOutCurve: AppMotion.standardReverse,
                  transitionBuilder: (child, animation) {
                    // Editor slides up from below; player content slides
                    // down when editor appears and back up when it leaves.
                    final isEditor = child.key == const ValueKey('editor');
                    final offset = isEditor
                        ? Tween<Offset>(begin: const Offset(0, 0.15), end: Offset.zero)
                        : Tween<Offset>(begin: const Offset(0, -0.08), end: Offset.zero);
                    return SlideTransition(
                      position: offset.animate(animation),
                      child: FadeTransition(opacity: animation, child: child),
                    );
                  },
                  child: _showEditor
                      ? KeyedSubtree(
                          key: const ValueKey('editor'),
                          child: LyricEditorDialog(
                            songTitle: _displayTrack.title,
                            rawTitle: _displayTrack.rawTitle,
                            artistName: _displayTrack.uploader,
                            coverUrl: _displayTrack.coverUrl,
                            positionNotifier:
                                _isActive ? widget.positionNotifier : null,
                            initialTabIndex: _editorLyricsTab ? 1 : 0,
                            currentLines:
                                _isActive ? widget.lyricsNotifier.value : const [],
                            currentTrackId: _isActive ? _displayTrack.id : null,
                            onClose: _closeEditor,
                            onApplyLyrics: (result) async {
                              if (_isActive) {
                                widget.lyricsNotifier.value = result.lines;
                              }
                              await DatabaseService.cacheLyrics(
                                  _displayTrack.id, result);
                              if (!mounted) return;
                              setState(() => _showLyrics = true);
                              _closeEditor();
                            },
                            onUpdateMetadata:
                                (newTitle, newArtist, newCoverUrl) async {
                              final updated = _displayTrack.copyWith(
                                title: newTitle,
                                uploader: newArtist,
                                coverUrl: newCoverUrl,
                              );
                              setState(() => _displayTrack = updated);
                              await DatabaseService.updateTrackMetadata(updated);
                              if (!mounted) return;
                              widget.handler.updateCurrentTrackMetadata(updated);
                              _closeEditor();
                            },
                          ),
                        )
                      : KeyedSubtree(
                          key: const ValueKey('player'),
                          child: Column(
                            children: [
                              _topBar(),
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 24, vertical: 8),
                                  child: AnimatedSwitcher(
                                    duration: AppMotion.base,
                                    switchInCurve: AppMotion.standard,
                                    switchOutCurve: AppMotion.standardReverse,
                                    transitionBuilder: (child, animation) {
                                      return FadeTransition(
                                        opacity: animation,
                                        child: ScaleTransition(
                                          scale: Tween<double>(begin: 0.92, end: 1.0)
                                              .animate(animation),
                                          child: child,
                                        ),
                                      );
                                    },
                                    child: _showLyrics && _isActive
                                        ? ValueListenableBuilder<List<LyricLine>>(
                                            key: const ValueKey('lyrics'),
                                            valueListenable: widget.lyricsNotifier,
                                            builder: (context, lines, _) {
                                              return SyncedLyricsView(
                                                lines: lines,
                                                positionNotifier:
                                                    widget.positionNotifier,
                                                onSeek: (sec) =>
                                                    widget.handler.seek(
                                                  Duration(
                                                      milliseconds:
                                                          (sec * 1000).toInt()),
                                                ),
                                                onOpenEditor: () =>
                                                    _openEditor(lyricsTab: true),
                                              );
                                            },
                                          )
                                        : _albumArt(),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
              ),
              _bottomPanel(),
            ],
          ),
        ),
      ),
    ],
  ),
),
);
}

  Widget _topBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.keyboard_arrow_down_rounded,
                color: context.palette.textSecondary, size: 30),
            tooltip: '收起',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          // The mark, not a caption. "正在播放" was 11pt of tracking-heavy text
          // announcing what the entire screen already is; the one thing worth
          // saying up here is when the screen is *not* that — a track being
          // previewed rather than played.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.asset('assets/logo.png', height: 30),
              ],
            ),
          ),
          IconButton(
            icon: Icon(
              _showLyrics ? Icons.lyrics_rounded : Icons.lyrics_outlined,
              color: _showLyrics && _isActive
                  ? context.palette.accent
                  : (_isActive ? context.palette.textSecondary : context.palette.textFaint),
              size: 22,
            ),
            tooltip: '歌词',
            onPressed: _isActive
                ? () {
                    Haptics.selection();
                    setState(() => _showLyrics = !_showLyrics);
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Widget _albumArt() {
    return LayoutBuilder(
      key: const ValueKey('art'),
      builder: (context, constraints) {
        final maxHeight = constraints.maxHeight;
        final size = maxHeight > 0
            ? (maxHeight * 0.82).clamp(160.0, constraints.maxWidth)
            : 240.0;
        return Center(
          child: AnimatedScale(
            scale: (_isActive && _isPlaying) ? 1.0 : 0.9,
            duration: AppMotion.slow,
            curve: AppMotion.springBouncy,
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                boxShadow: const [
                  BoxShadow(
                    color: AppColors.black55,
                    blurRadius: 44,
                    spreadRadius: -6,
                    offset: Offset(0, 20),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.xl),
                child: CachedCoverImage(
                  url: _displayTrack.coverUrl,
                  width: size,
                  height: size,
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _bottomPanel() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!_showEditor) ...[
            Row(
              children: [
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      MarqueeText(
                        text: _displayTrack.title,
                        style: AppTypography.title,
                      ),
                      const SizedBox(height: 4),
                      MarqueeText(
                        text: _displayTrack.uploader,
                        phase: 0.35,
                        style: AppTypography.bodyMedium,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: HugeIcon(icon: HugeIcons.strokeRoundedEdit02,
                      color: context.palette.textSecondary, size: 24),
                  tooltip: '编辑',
                  onPressed: () => _openEditor(lyricsTab: _showLyrics),
                ),
                _favoriteButton(),
              ],
            ),
            const SizedBox(height: 10),
          ],
          _seekBar(),
          const SizedBox(height: 4),
          _transportControls(),

        ],
      ),
    );
  }

  Widget _seekBar() {
    return PlayerSeekBar(
      positionNotifier: widget.positionNotifier,
      durationNotifier: widget.durationNotifier,
      fallbackSeconds: _displayTrack.duration > 0
          ? _displayTrack.duration.toDouble()
          : 1.0,
      isActive: _isActive,
      onSeek: widget.handler.seek,
    );
  }

  Widget _transportControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        _modeButton(),
        _skipButton(Icons.skip_previous_rounded,
            _isActive && widget.handler.canSkipPrevious ? _prev : null),
        _playButton(),
        _skipButton(Icons.skip_next_rounded,
            _isActive && widget.handler.canSkipNext ? _next : null),
        _queueButton(),
      ],
    );
  }

  Widget _queueButton() {
    final enabled = widget.handler.playbackQueue.isNotEmpty &&
        widget.handler.currentTrack != null;
    return SizedBox(
      width: 48,
      child: IconButton(
        icon: HugeIcon(icon: HugeIcons.strokeRoundedListMusic,
            color: enabled ? context.palette.textMuted : context.palette.textFaint,
            size: 25),
        tooltip: '播放列表',
        onPressed: enabled
            ? () => showPlayerQueueSheet(
                context: context,
                handler: widget.handler,
                onQueueCleared: widget.onQueueCleared,
              )
            : null,
      ),
    );
  }

  Widget _skipButton(IconData icon, VoidCallback? onPressed) {
    return IconButton(
      icon: Icon(icon,
          color: onPressed == null
              ? context.palette.textFaint
              : context.palette.textPrimary,
          size: 40),
      onPressed: onPressed,
    );
  }

  Widget _favoriteButton() {
    return SizedBox(
      width: 48,
      child: IconButton(
        icon: Icon(
          _isFavorite ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          color: _isFavorite ? context.palette.accent : context.palette.textMuted,
          size: 26,
        ),
        tooltip: _isFavorite ? '取消收藏' : '收藏',
        onPressed: _handleFavorite,
      ),
    );
  }

  /// The primary control mirrors the track's real state, because playback is
  /// download-then-play: a track that is not on disk cannot be played, so it
  /// offers a download (with the same progress ring used in the lists) and
  /// only becomes play/pause once the file is there.
  Widget _playButton() {
    final task = _downloadTask;

    // Download and downloading are the *same button*, not two designs: the
    // circle, its fill, its border and its glyph are identical, and starting a
    // download only adds a progress arc around the outside. Previously the
    // filled circle was replaced by a bare thin ring, so the control appeared
    // to vanish the instant you tapped it.
    if (task != null || !_isDownloaded) {
      return _circleButton(
        tooltip: task != null ? '下载中' : '下载',
        onPressed: task != null ? null : _startDownload,
        filled: false,
        progress: task?.fraction,
        icon: HugeIcon(icon: HugeIcons.strokeRoundedDownload04,
            color: context.palette.textPrimary, size: 34),
      );
    }

    final playing = _isActive && _isPlaying;
    return _circleButton(
      tooltip: playing ? '暂停' : '播放',
      onPressed: _playOrPause,
      filled: true,
      icon: AnimatedSwitcher(
        duration: AppMotion.instant,
        transitionBuilder: (child, animation) =>
            ScaleTransition(scale: animation, child: child),
        child: Icon(
          playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          key: ValueKey<bool>(playing),
          color: context.palette.textPrimary,
          size: 40,
        ),
      ),
    );
  }

  /// The one primary-control shape. [progress], when set, draws a determinate
  /// arc just outside the circle without altering the circle itself.
  Widget _circleButton({
    required Widget icon,
    required VoidCallback? onPressed,
    required String tooltip,
    required bool filled,
    double? progress,
  }) {
    final button = Container(
      width: 68,
      height: 68,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: filled ? context.palette.primaryGradient : null,
        color: filled ? null : context.palette.surfaceCard,
        border: filled
            ? null
            : Border.all(color: context.palette.hairline),
        boxShadow: filled
            ? [
                BoxShadow(
                  color: context.palette.accent30,
                  blurRadius: 22,
                  offset: Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: IconButton(
        onPressed: onPressed,
        tooltip: tooltip,
        icon: icon,
      ),
    );

    // Always occupy the same 76×76 footprint so adding/removing the
    // progress ring never reflows the transport row.
    return SizedBox(
      width: 76,
      height: 76,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (progress != null)
            ProgressRing(
              fraction: progress,
              size: 76,
              strokeWidth: 3,
              trackColor: AppColors.hairline,
            ),
          button,
        ],
      ),
    );
  }

  Widget _modeButton() {
    final icon = _isShuffle
        ? HugeIcons.strokeRoundedShuffle
        : (_loopMode == LoopMode.one
            ? HugeIcons.strokeRoundedRepeatOne01
            : HugeIcons.strokeRoundedRepeat);
    final label = _isShuffle
        ? '随机播放'
        : (_loopMode == LoopMode.one ? '单曲循环' : '列表循环');
    return SizedBox(
      width: 48,
      child: IconButton(
        icon: HugeIcon(icon: icon, color: context.palette.textMuted, size: 24),
        tooltip: label,
        onPressed: () {
          Haptics.medium();
          widget.handler.cyclePlayMode();
        },
      ),
    );
  }

}
