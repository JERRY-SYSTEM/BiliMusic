import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import '../models/lyric_line.dart';
import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../services/bilibili_sdk.dart';
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
import 'lyric_search_sheet.dart';
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
  late final PageController _pageController;

  late Track _displayTrack;
  bool _followHandler = false;
  bool _isPlaying = false;
  bool _isShuffle = false;
  LoopMode _loopMode = LoopMode.all;
  int _currentPage = 1;
  int _detailsToken = 0;
  bool _showTranslation = true;
  bool _isFavorite = false;
  bool _isDownloaded = false;
  DownloadTask? _downloadTask;
  VoidCallback? _editorRelease;

  bool get _isActive => widget.handler.currentTrack?.id == _displayTrack.id;

  @override
  void initState() {
    super.initState();
    final h = widget.handler;
    _pageController = PageController(initialPage: 1);
    _displayTrack = widget.focusedTrack;
    _followHandler =
        widget.followHandler || (h.currentTrack?.id == _displayTrack.id);
    _isPlaying = h.isPlaying;
    _isShuffle = h.isShuffle;
    _loopMode = h.loopMode;
    _downloadTask = _liveTaskFor(_displayTrack.id);
    _refreshTrackState();
    _hydrateDetails(_displayTrack);

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
        _hydrateDetails(t);
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
    _pageController.dispose();
    _editorRelease?.call();
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }

  Future<void> _hydrateDetails(Track track) async {
    if (track.bvid.trim().isEmpty) return;
    final token = ++_detailsToken;
    final hydrated = await BilibiliSdk.hydrateTrackDetails(track);
    if (!mounted || token != _detailsToken || _displayTrack.id != track.id) {
      return;
    }
    if (identical(hydrated, track)) return;
    final current = _displayTrack;
    final merged = current.copyWith(
      rawTitle: hydrated.rawTitle,
      originalUploader: hydrated.originalUploader,
      publishTime: hydrated.publishTime,
      description: hydrated.description,
      playCount: hydrated.playCount,
      danmakuCount: hydrated.danmakuCount,
      likeCount: hydrated.likeCount,
      coinCount: hydrated.coinCount,
      favoriteCount: hydrated.favoriteCount,
      shareCount: hydrated.shareCount,
      replyCount: hydrated.replyCount,
      duration: current.duration > 0 ? current.duration : hydrated.duration,
    );
    setState(() => _displayTrack = merged);
    await DatabaseService.updateTrackMetadata(merged);
    if (mounted && _displayTrack.id == merged.id && _isActive) {
      widget.handler.updateCurrentTrackMetadata(merged);
    }
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

  Future<void> _openEditor() async {
    Haptics.selection();
    _editorRelease?.call();
    _editorRelease = widget.handler.holdAutoAdvance();
    try {
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: context.palette.backgroundElevated,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (sheetContext) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(sheetContext).bottom,
          ),
          child: SafeArea(
            top: false,
            child: FractionallySizedBox(
              heightFactor: 0.7,
              child: LyricEditorDialog(
                songTitle: _displayTrack.title,
                rawTitle: _displayTrack.rawTitle,
                artistName: _displayTrack.uploader,
                coverUrl: _displayTrack.coverUrl,
                onUpdateMetadata: (newTitle, newArtist, newCoverUrl) async {
                  final updated = _displayTrack.copyWith(
                    title: newTitle,
                    uploader: newArtist,
                    coverUrl: newCoverUrl,
                  );
                  if (mounted) setState(() => _displayTrack = updated);
                  await DatabaseService.updateTrackMetadata(updated);
                  if (!mounted) return;
                  widget.handler.updateCurrentTrackMetadata(updated);
                  Navigator.of(sheetContext).pop();
                },
              ),
            ),
          ),
        ),
      );
    } finally {
      _editorRelease?.call();
      _editorRelease = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // The same backdrop as the rest of the app — the aura at the top, black
      // below — rather than a flat black page. The route morph paints its own
      // opaque surface underneath, so this stays honest during the transition.
      backgroundColor: context.palette.background,
      body: Stack(
        children: [
          Positioned.fill(
            child: AmbientBackground(coverUrl: _displayTrack.coverUrl),
          ),
          GestureDetector(
            // Swipe down anywhere on the chrome to dismiss, like the system sheets.
            onVerticalDragEnd: (details) {
              if ((details.primaryVelocity ?? 0) > 320) {
                Haptics.selection();
                Navigator.of(context).maybePop();
              }
            },
            child: SafeArea(
              minimum: const EdgeInsets.only(top: 16),
              child: Column(
                children: [
                  Expanded(
                    child: Column(
                      children: [
                        _topBar(),
                        Expanded(
                          child: PageView(
                            key: const Key('playerPageView'),
                            controller: _pageController,
                            onPageChanged: (page) {
                              Haptics.selection();
                              setState(() => _currentPage = page);
                            },
                            children: [
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                                child: _metadataPage(),
                              ),
                              Column(
                                children: [
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 24, vertical: 8),
                                      child: _albumArt(),
                                    ),
                                  ),
                                  _bottomPanel(),
                                ],
                              ),
                              Padding(
                                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                                child: _lyricsPage(),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _topBar() {
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          IconButton(
            icon: Icon(Icons.keyboard_arrow_down_rounded,
                color: context.palette.textSecondary, size: 30),
            tooltip: '收起',
            onPressed: () => Navigator.of(context).maybePop(),
          ),
          Expanded(
            child: Center(child: _pageIndicator()),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }

  Future<void> _openLyricSearch() async {
    Haptics.selection();
    final track = _displayTrack;
    final release = widget.handler.holdAutoAdvance();
    try {
      await showLyricSearchSheet(
        context: context,
        initialKeyword: track.title.trim(),
        onApply: (result) async {
          if (widget.handler.currentTrack?.id == track.id) {
            widget.lyricsNotifier.value = result.lines;
          }
          await DatabaseService.cacheLyrics(track.id, result);
        },
      );
    } finally {
      release();
    }
  }

  Widget _pageIndicator() {
    return AnimatedBuilder(
      animation: _pageController,
      builder: (context, _) {
        final page = _pageController.hasClients &&
                _pageController.position.hasContentDimensions
            ? (_pageController.page ?? _currentPage.toDouble())
            : _currentPage.toDouble();
        return Row(
          key: const Key('playerPageIndicator'),
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (index) {
            final proximity =
                (1 - (page - index).abs()).clamp(0.0, 1.0).toDouble();
            return Container(
              width: 3 + 9 * proximity,
              height: 3,
              margin: EdgeInsets.only(right: index == 2 ? 0 : 8),
              decoration: BoxDecoration(
                color: Color.lerp(
                  context.palette.textFaint,
                  context.palette.textPrimary,
                  proximity,
                ),
                borderRadius: BorderRadius.circular(999),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _metadataPage() {
    final track = _displayTrack;
    final stats = <({dynamic icon, String label, int? value})>[
      (icon: HugeIcons.strokeRoundedPlayCircle02, label: '播放', value: track.playCount),
      (icon: HugeIcons.strokeRoundedSubtitle, label: '弹幕', value: track.danmakuCount),
      (icon: HugeIcons.strokeRoundedThumbsUp, label: '点赞', value: track.likeCount),
      (icon: HugeIcons.strokeRoundedDollarCircle, label: '投币', value: track.coinCount),
      (icon: HugeIcons.strokeRoundedStar, label: '收藏', value: track.favoriteCount),
      (icon: HugeIcons.strokeRoundedShare01, label: '分享', value: track.shareCount),
      (icon: HugeIcons.strokeRoundedComment01, label: '评论', value: track.replyCount),
      (icon: HugeIcons.strokeRoundedComingSoon02, label: '时长', value: null),
    ];
    return ListView(
      key: const Key('playerMetadataPage'),
      physics: const BouncingScrollPhysics(),
      children: [
        _infoCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _sectionTitle('播放信息'),
              const SizedBox(height: 8),
              _metadataRow('标题', track.rawTitle.isEmpty ? '--' : track.rawTitle),
              _metadataRow('UP主', track.originalUploader ?? '--'),
              _metadataRow('发布时间', _formatPublishTime(track.publishTime)),
              _metadataRow('BV', track.bvid.isEmpty ? '--' : track.bvid),
              _metadataRow('时长', _formatSeconds(track.duration), isLast: true),
            ],
          ),
        ),
        const SizedBox(height: 14),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: stats.length,
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 2,
            mainAxisSpacing: 10,
            crossAxisSpacing: 10,
            childAspectRatio: 1.9,
          ),
          itemBuilder: (context, index) {
            final stat = stats[index];
            final value = stat.label == '时长'
                ? _formatSeconds(track.duration)
                : _formatCount(stat.value);
            return _statCard(stat.icon, stat.label, value);
          },
        ),
        if ((track.description ?? '').trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          _infoCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionTitle('简介'),
                const SizedBox(height: 10),
                Text(
                  track.description!.trim(),
                  style: TextStyle(
                    color: context.palette.textSecondary,
                    fontSize: 14,
                    height: 1.55,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _infoCard({required Widget child}) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: context.palette.backgroundElevated.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(28),
          border: Border.all(color: context.palette.accent.withValues(alpha: 0.14)),
        ),
        child: child,
      );

  Widget _sectionTitle(String text) => Text(
        text,
        style: TextStyle(
          color: context.palette.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w800,
        ),
      );

  Widget _metadataRow(String label, String value, {bool isLast = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(
        border: isLast
            ? null
            : Border(bottom: BorderSide(color: context.palette.accent12)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(label,
                style: TextStyle(
                    color: context.palette.textMuted,
                    fontWeight: FontWeight.w700)),
          ),
          Expanded(
            child: Text(value,
                style: TextStyle(
                    color: context.palette.textPrimary,
                    fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _statCard(dynamic icon, String label, String value) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: context.palette.backgroundElevated.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: context.palette.accent12),
        ),
        child: Row(
          children: [
            Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: context.palette.accent12,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Transform.scale(
                scale: 0.6,
                child: HugeIcon(
                  icon: icon,
                  color: context.palette.accent,
                  size: 24,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(
                          color: context.palette.textMuted,
                          fontSize: 12,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 3),
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          color: context.palette.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w800)),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _lyricsPage() {
    return Column(
      key: const Key('playerLyricsPage'),
      children: [
        Expanded(
          child: ValueListenableBuilder<List<LyricLine>>(
            valueListenable: widget.lyricsNotifier,
            builder: (context, lines, _) => SyncedLyricsView(
              lines: _isActive ? lines : const [],
              positionNotifier: widget.positionNotifier,
              showTranslation: _showTranslation,
              onSeek: _isActive
                  ? (seconds) => widget.handler.seek(
                        Duration(milliseconds: (seconds * 1000).round()),
                      )
                  : null,
            ),
          ),
        ),
        ValueListenableBuilder<List<LyricLine>>(
          valueListenable: widget.lyricsNotifier,
          builder: (context, lines, _) {
            final hasTranslation = lines.any(
              (line) => (line.translation ?? '').trim().isNotEmpty,
            );
            return SafeArea(
              top: false,
              child: Row(
                children: [
                  IconButton(
                    key: const Key('lyricSearchButton'),
                    tooltip: '手动匹配歌词',
                    color: context.palette.accent,
                    onPressed: _openLyricSearch,
                    icon: const HugeIcon(icon: HugeIcons.strokeRoundedSearchList02),
                  ),
                  if (hasTranslation) ...[
                    const SizedBox(width: 20),
                    IconButton(
                      tooltip: _showTranslation ? '隐藏译文' : '显示译文',
                      color: context.palette.accent.withValues(
                        alpha: _showTranslation ? 1 : 0.45,
                      ),
                      onPressed: () => setState(
                        () => _showTranslation = !_showTranslation,
                      ),
                      icon: const HugeIcon(icon: HugeIcons.strokeRoundedTranslate),
                    ),
                  ],
                ],
              ),
            );
          },
        ),
      ],
    );
  }

  String _formatPublishTime(int? seconds) {
    if (seconds == null || seconds <= 0) return '--';
    final date = DateTime.fromMillisecondsSinceEpoch(seconds * 1000).toLocal();
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  String _formatSeconds(int seconds) {
    if (seconds <= 0) return '--:--';
    final duration = Duration(seconds: seconds);
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final secs = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return duration.inHours > 0
        ? '${duration.inHours}:$minutes:$secs'
        : '$minutes:$secs';
  }

  String _formatCount(int? value) {
    if (value == null || value < 0) return '--';
    if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
    if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
    return value.toString();
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
                  onPressed: _openEditor,
                ),
                _favoriteButton(),
              ],
            ),
          const SizedBox(height: 10),
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
