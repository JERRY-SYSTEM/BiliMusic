import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'models/track.dart';
import 'models/playlist.dart';
import 'models/lyric_line.dart';
import 'models/bili_favorite_collection.dart';
import 'services/lyrics_engine.dart';
import 'services/database_service.dart';
import 'services/audio_player_handler.dart';
import 'services/audio_download_service.dart';
import 'services/app_settings_service.dart';
import 'services/bili_auth_service.dart';
import 'services/bili_favorites_service.dart';
import 'theme/app_theme.dart';
import 'theme/haptics.dart';
import 'theme/motion.dart';
import 'widgets/ambient_background.dart';
import 'widgets/expand_from_card.dart';
import 'widgets/mini_player.dart';
import 'widgets/now_playing_sheet.dart';
import 'widgets/playlist_detail_sheet.dart';
import 'widgets/segment_tabs.dart';
import 'screens/home_screen.dart';
import 'screens/search_screen.dart';
import 'widgets/bili_auth_page.dart';
import 'widgets/settings_page.dart';

import 'package:audio_service/audio_service.dart';

BiliBeatAudioHandler? _audioHandlerInstance;

/// Adapts a [PageController] — a Listenable whose `page` is null until the
/// first frame — into the [Animation] [SegmentTabs] drives its pill with.
/// The fallback index covers the brief window before the view attaches.
class _PageFraction extends Animation<double> with ChangeNotifier {
  _PageFraction(this._controller, this._fallbackIndex) {
    _controller.addListener(notifyListeners);
  }

  /// Balances the listener added in the constructor — [MainLayout] owns one
  /// instance for its lifetime; constructing one per build (the old way)
  /// leaked a listener on the PageController on every rebuild.
  @override
  void dispose() {
    _controller.removeListener(notifyListeners);
    super.dispose();
  }

  final PageController _controller;
  final int _fallbackIndex;

  @override
  double get value {
    if (!_controller.hasClients) return _fallbackIndex.toDouble();
    return (_controller.page ?? _fallbackIndex.toDouble()).clamp(0.0, 1.0);
  }

  // A drag-following fraction has no discrete status; nothing in SegmentTabs
  // reads it, so it stays permanently "active".
  @override
  AnimationStatus get status => AnimationStatus.forward;

  @override
  void addStatusListener(AnimationStatusListener listener) {}

  @override
  void removeStatusListener(AnimationStatusListener listener) {}
}

/// The one handler registered with `audio_service`. Reading this before
/// [main] has initialised it is a programming error — lazily constructing a
/// second handler here would silently detach playback from the OS media
/// session, so we fail loudly instead.
BiliBeatAudioHandler get audioHandlerInstance {
  final handler = _audioHandlerInstance;
  assert(handler != null, 'audioHandlerInstance read before AudioService.init');
  return handler!;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettingsService.instance.initialize();
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 * 1024 * 1024;
  PaintingBinding.instance.imageCache.maximumSize = 60;
  // Edge to edge, with a transparent navigation bar and — the part that
  // matters — no divider. Android draws a hairline above the gesture area by
  // default, which is the line that kept showing under the docked player no
  // matter how flush the card itself was.
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
    systemNavigationBarColor: Colors.transparent,
    systemNavigationBarDividerColor: Colors.transparent,
    systemNavigationBarIconBrightness: Brightness.light,
    systemNavigationBarContrastEnforced: false,
  ));
  _audioHandlerInstance = await AudioService.init(
    builder: BiliBeatAudioHandler.new,
    config: const AudioServiceConfig(
      androidNotificationChannelId: 'com.bilibeat.channel.audio',
      androidNotificationChannelName: 'BiliBeat',
      androidNotificationOngoing: true,
    ),
  );
  // Android 13+ requires a runtime POST_NOTIFICATIONS grant for notifications
  // on stricter OEM builds. Fire-and-forget: stock Android exempts the media
  // session notification, so the answer is "no" on most devices and that is
  // fine either way.
  if (!kIsWeb && Platform.isAndroid) {
    const channel = MethodChannel('bilibeat/permissions');
    try {
      await channel.invokeMethod('requestNotifications');
    } catch (_) {}
  }
  runApp(const BiliBeatApp());
}

class BiliBeatApp extends StatelessWidget {
  const BiliBeatApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = AppSettingsService.instance;
    return AnimatedBuilder(
      animation: settings,
      builder: (context, _) => MaterialApp(
        title: 'BiliBeat',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(ThemeMode.light, Color(settings.accentValue)),
        darkTheme: AppTheme.build(ThemeMode.dark, Color(settings.accentValue)),
        themeMode: settings.themeMode == 'system' ? ThemeMode.system :
            settings.themeMode == 'light' ? ThemeMode.light : ThemeMode.dark,
        home: const MainLayout(),
      ),
    );
  }
}

class MainLayout extends StatefulWidget {
  const MainLayout({super.key});

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  int _activeTabIndex = 0;
  late final BiliBeatAudioHandler _audioHandler = audioHandlerInstance;

  /// Player state is held in notifiers, not State fields. It changes on every
  /// play/pause and every track advance, and as plain `setState` state it
  /// rebuilt the whole tree — both page subtrees included — for a change that
  /// only the ambient backdrop and the docked bar care about.
  /// Not a `ValueNotifier<Track?>`: [Track] equality is id-only, so a
  /// ValueNotifier would drop the metadata-edit assignment (same id, new
  /// title/cover) and leave the docked player showing stale text.
  final TrackNotifier _currentTrack = TrackNotifier();
  final ValueNotifier<bool> _isPlaying = ValueNotifier(false);
  final ValueNotifier<Duration> _positionNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<Duration> _durationNotifier =
      ValueNotifier(Duration.zero);
  final ValueNotifier<List<LyricLine>> _lyricsNotifier = ValueNotifier([]);
  /// Also a notifier, and for the same reason as the player state above: the
  /// handler writes a history entry on *every* track change, and holding this
  /// in `setState` state rebuilt both page subtrees each time a song started —
  /// for a change only the 最近播放 rail cares about.
  final ValueNotifier<List<Track>> _recentlyPlayed = ValueNotifier(const []);
  Playlist? _activePlaylistSheet;

  late final PageController _pageController = PageController();

  /// One instance for the widget's lifetime (see [_PageFraction.dispose]).
  late final _PageFraction _pageFraction = _PageFraction(_pageController, 0);
  final List<StreamSubscription> _subs = [];

  @override
  void initState() {
    super.initState();
    BiliAuthController.instance.addListener(_onAuthChanged);
    unawaited(BiliAuthController.instance.initialize());
    _initListeners();
    _loadHistory();
  }

  @override
  void dispose() {
    BiliAuthController.instance.removeListener(_onAuthChanged);
    for (final s in _subs) {
      s.cancel();
    }
    _currentTrack.dispose();
    _recentlyPlayed.dispose();
    _isPlaying.dispose();
    _positionNotifier.dispose();
    _durationNotifier.dispose();
    _lyricsNotifier.dispose();
    _pageFraction.dispose();
    _pageController.dispose();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _openLogin() async {
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => const BiliAuthPage()));
  }

  Future<void> _importFavorites() async {
    final auth = BiliAuthController.instance;
    if (auth.session?.isLoggedIn != true) {
      final login = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppColors.backgroundElevated,
          title: const Text('需要登录', style: TextStyle(color: AppColors.textPrimary)),
          content: const Text('请先登录 B 站账号，再导入收藏夹。', style: TextStyle(color: AppColors.textSecondary)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('去登录', style: TextStyle(color: AppColors.accent))),
          ],
        ),
      );
      if (login == true) await _openLogin();
      return;
    }
    final collection = await showDialog<BiliFavoriteCollection>(
      context: context,
      builder: (_) => FavoritePickerDialog(session: auth.session!),
    );
    if (!mounted || collection == null) return;
final tracks = await showDialog<List<Track>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => FavoriteTracksDialog(session: auth.session!, collection: collection),
    );
    if (!mounted || tracks == null || tracks.isEmpty) return;
    final destination = await _showImportDestination();
    if (!mounted || destination == null) return;
    Playlist target;
    if (destination.existingId != null) {
      target = (await DatabaseService.getPlaylists()).firstWhere((p) => p.id == destination.existingId);
    } else {
      target = await DatabaseService.createPlaylist(destination.name!.isEmpty ? collection.name : destination.name!);
      if (collection.coverUrl?.isNotEmpty == true) await DatabaseService.setPlaylistCover(target.id, collection.coverUrl);
    }
    final before = target.tracks.length;
    await DatabaseService.addTracksToPlaylist(target.id, tracks);
    final after = (await DatabaseService.getPlaylists()).firstWhere((p) => p.id == target.id).tracks.length;
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已导入 ${after - before} 首，跳过 ${tracks.length - (after - before)} 首')));
  }

  Future<ImportDestination?> _showImportDestination() async {
    final playlists = (await DatabaseService.getPlaylists()).where((p) => p.id != Playlist.favoritesId).toList();
    final nameController = TextEditingController();
    String? existingId;
    bool createNew = true;
    final result = await showDialog<ImportDestination>(
      context: context,
      builder: (ctx) => StatefulBuilder(builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: AppColors.backgroundElevated,
        title: const Text('选择导入目标', style: TextStyle(color: AppColors.textPrimary)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          RadioListTile<bool>(value: true, groupValue: createNew, onChanged: (v) => setDialogState(() => createNew = true), title: const Text('新建本地歌单')),
          if (createNew) TextField(controller: nameController, decoration: const InputDecoration(hintText: '歌单名称')),
          RadioListTile<bool>(value: false, groupValue: createNew, onChanged: playlists.isEmpty ? null : (v) => setDialogState(() { createNew = false; existingId ??= playlists.first.id; }), title: const Text('添加到已有歌单')),
          if (!createNew && playlists.isNotEmpty) DropdownButton<String>(value: existingId ?? playlists.first.id, isExpanded: true, items: playlists.map((p) => DropdownMenuItem(value: p.id, child: Text(p.name))).toList(), onChanged: (v) => setDialogState(() => existingId = v)),
          if (!createNew && playlists.isEmpty) const Text('暂无可用本地歌单'),
        ]),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')), TextButton(onPressed: !createNew && playlists.isEmpty ? null : () => Navigator.pop(ctx, createNew ? ImportDestination.newPlaylist(nameController.text.trim()) : ImportDestination.existing(existingId!)), child: const Text('导入', style: TextStyle(color: AppColors.accent)))],
      )),
    );
    nameController.dispose();
    return result;
  }

  void _initListeners() {
    _subs.add(_audioHandler.currentTrackStream.listen((track) async {
      if (track != null) {
        _currentTrack.value = track;

        // Fetch lyrics with stale cache validation.
        //
        // Every await below needs a `mounted` guard: cancelling the
        // subscription in dispose() stops *new* events, but an event already
        // being handled resumes after its await regardless — and writing to a
        // disposed ValueNotifier throws.
        final cleanSongTitle =
            LyricsEngine.cleanTitle(track.rawTitle)['songTitle'] ?? '';
        final cached = await DatabaseService.getCachedLyrics(track.id);
        if (!mounted || _currentTrack.value?.id != track.id) return;

        bool isCacheValid = false;
        if (cached != null && cached.lines.isNotEmpty && cached.source != 'none') {
          // 'user' (pasted/edited LRC) and 'current' (re-applied with an
          // offset) are deliberate user choices. Title-validating them fails
          // — a paste is cached as 「自定义歌词」 — and the refetch below then
          // silently overwrote the user's lyrics with the provider's.
          if (cached.source == 'user' || cached.source == 'current') {
            isCacheValid = true;
          } else {
            final cachedTitle = cached.songTitle ?? '';
            if (cachedTitle.isNotEmpty && LyricsEngine.isTitleMatching(cachedTitle, cleanSongTitle)) {
              isCacheValid = true;
            }
          }
        }

        if (isCacheValid) {
          _lyricsNotifier.value = cached!.lines;
        } else {
          _lyricsNotifier.value = const [];
          final freshLyrics = await LyricsEngine.autoFetchLyrics(track.rawTitle);
          if (!mounted || _currentTrack.value?.id != track.id) return;
          // A "not found" result carries placeholder lines; showing an empty
          // list instead lets the lyrics view offer its search/paste action.
          _lyricsNotifier.value =
              freshLyrics.source == 'none' ? const [] : freshLyrics.lines;
          await DatabaseService.cacheLyrics(track.id, freshLyrics);
        }
      }
    }));

    _subs.add(_audioHandler.playerStateStream.listen((playing) {
      _isPlaying.value = playing;
    }));

    _subs.add(_audioHandler.positionStream.listen((pos) {
      _positionNotifier.value = pos;
    }));

    _subs.add(_audioHandler.durationStream.listen((dur) {
      _durationNotifier.value = dur;
    }));

    // The handler writes history itself when it auto-advances, so the rail has
    // to follow the store rather than the UI actions that happen to reach it.
    _subs.add(DatabaseService.historyUpdateStream.listen((_) => _loadHistory()));
  }

  Future<void> _loadHistory() async {
    final history = await DatabaseService.getRecentlyPlayed();
    if (mounted) _recentlyPlayed.value = history;
  }

  /// Resolve the loop/shuffle queue: a playlist/favorites passes its own
  /// tracks; anywhere else passes null and we default to the whole downloaded
  /// library.
  Future<List<Track>> _resolveQueue(List<Track>? queue) async {
    if (queue != null && queue.isNotEmpty) return queue;
    return DatabaseService.getDownloadedTracks();
  }

  /// Starts a whole collection — 本地, 收藏, a playlist — rather than one
  /// track. Loop-all either way; shuffle is the caller's choice, and it is set
  /// *before* the queue is handed over so the shuffle order is built around
  /// the track that starts.
  void _playCollection(List<Track> tracks, {bool shuffle = false}) async {
    if (tracks.isEmpty) return;
    await _audioHandler.setShuffle(shuffle);
    await _audioHandler.setLoopMode(LoopMode.all);
    if (!mounted) return;
    final first =
        shuffle ? tracks[Random().nextInt(tracks.length)] : tracks.first;
    _currentTrack.value = first;
    _audioHandler.playTrack(first, newQueue: tracks);
  }

  void _onPlayTrackOnly(Track track, {List<Track>? queue}) async {
    _currentTrack.value = track;
    final q = await _resolveQueue(queue);
    _audioHandler.playTrack(track, newQueue: q.isNotEmpty ? q : null);
  }

  void _onPlayTrackAndExpand(Track track, {List<Track>? queue}) async {
    _currentTrack.value = track;
    _openNowPlaying(track: track, follow: true);
    final q = await _resolveQueue(queue);
    _audioHandler.playTrack(track, newQueue: q.isNotEmpty ? q : null);
  }

  /// Search tap: preview an undownloaded track in the player sheet without
  /// auto-downloading; play straight away (looping the downloaded library) if
  /// it's already local.
  void _onSearchSelectTrack(Track track, {List<Track>? queue}) async {
    final downloaded = await AudioDownloadService.isDownloaded(track);
    if (!mounted) return;
    if (downloaded) {
      _onPlayTrackAndExpand(track, queue: queue);
    } else {
      _openNowPlaying(track: track);
    }
  }

  bool _nowPlayingOpen = false;
  final GlobalKey _miniPlayerKey = GlobalKey();

  /// Where the docked card is on screen right now, or null if it is not laid
  /// out (nothing playing yet, first frame).
  Rect? _miniPlayerRect() {
    final box = _miniPlayerKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return null;
    // The card is flush to the bottom and the sides, so its slot *is* the card
    // — no margins to subtract.
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _openNowPlaying({Track? track, bool follow = false}) {
    final focused = track ?? _currentTrack.value;
    if (focused == null) return;
    // A double tap used to stack two identical full-screen routes.
    if (_nowPlayingOpen) return;
    _nowPlayingOpen = true;

    final from = _miniPlayerRect();

    Navigator.of(context).push(
      PageRouteBuilder(
        transitionDuration: AppMotion.slow,
        reverseTransitionDuration: AppMotion.base,
        pageBuilder: (context, animation, secondaryAnimation) {
          return NowPlayingSheet(
            handler: _audioHandler,
            focusedTrack: focused,
            positionNotifier: _positionNotifier,
            durationNotifier: _durationNotifier,
            lyricsNotifier: _lyricsNotifier,
            followHandler: follow,
          );
        },
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          // The docked card *becomes* the page: its rectangle grows to fill
          // the screen and its corner radius unrolls, and on the way back it
          // folds down onto the card again. Falling back to a slide-up keeps
          // the entry sane when there is no card to grow from (opened straight
          // from a search result before anything is docked).
          if (from == null) {
            return SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(CurvedAnimation(
                parent: animation,
                curve: AppMotion.standard,
                reverseCurve: AppMotion.standardReverse,
              )),
              child: child,
            );
          }
          return ExpandFromCard(animation: animation, from: from, child: child);
        },
      ),
    ).whenComplete(() => _nowPlayingOpen = false);
  }




  void _onTabTap(int index) {
    if (index == _activeTabIndex) return;
    Haptics.selection();
    setState(() => _activeTabIndex = index);
    _pageController.animateToPage(
      index,
      duration: AppMotion.base,
      curve: AppMotion.emphasized,
    );
  }


  @override
  Widget build(BuildContext context) {
    final dockedHeight = MiniPlayer.totalHeight(context);

    return Scaffold(
      body: Stack(
        children: [
          // Layer 0: ambient backdrop. A sibling behind the content rather
          // than its parent, so a cover change repaints only this layer
          // instead of rebuilding both pages.
          Positioned.fill(
            child: ValueListenableBuilder<Track?>(
              valueListenable: _currentTrack,
              builder: (context, track, _) =>
                  AmbientBackground(coverUrl: track?.coverUrl),
            ),
          ),
          Stack(
          children: [
            // Layer 1: Content Pages
            Column(
              children: [
                // Top Tab Header Selector ("聆听" | "搜索") — sliding pill
                SafeArea(
                  bottom: false,
                  minimum: const EdgeInsets.only(top: 12),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: SegmentTabs(
                            labels: const ['聆听', '搜索'],
                            animation: _pageFraction,
                            onTap: _onTabTap,
                          ),
                        ),
                        IconButton(
                          tooltip: BiliAuthController.instance.session?.isLoggedIn == true ? '已登录' : '登录',
                          onPressed: _openLogin,
                          icon: BiliAuthController.instance.session?.face?.isNotEmpty == true
                              ? CircleAvatar(radius: 15, backgroundImage: NetworkImage(BiliAuthController.instance.session!.face!))
                              : const Icon(Icons.account_circle_outlined, color: AppColors.textSecondary),
                        ),
                        IconButton(
                          tooltip: '设置',
                          onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsPage())),
                          icon: const Icon(Icons.settings_outlined, color: AppColors.textSecondary),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(left: 4, right: 6),
                          child: Image.asset('assets/logo.png', height: 32),
                        ),
                      ],
                    ),
                  ),
                ),

                // Swipeable PageView (聆听 & 搜索)
                Expanded(
                  child: PageView(
                    controller: _pageController,
                    onPageChanged: (index) {
                      Haptics.selection();
                      setState(() {
                        _activeTabIndex = index;
                      });
                    },
                    children: [
                      RepaintBoundary(
                        child: ValueListenableBuilder<List<Track>>(
                          valueListenable: _recentlyPlayed,
                          builder: (context, recent, _) => HomeScreen(
                            recentlyPlayed: recent,
                            onSelectTrack: _onPlayTrackAndExpand,
                            onPlayOnly: _onPlayTrackOnly,
                            onPlayCollection: _playCollection,
                            onOpenPlaylist: (pl) {
                              setState(() => _activePlaylistSheet = pl);
                            },
                          ),
                        ),
                      ),
                      RepaintBoundary(
                        child: SearchScreen(
                          onSelectTrack: _onSearchSelectTrack,
                          onPlayOnly: _onPlayTrackOnly,
                        ),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: dockedHeight),
              ],
            ),

            // Layer 2: Active Playlist Overlay (Stops strictly above MiniPlayer)
            if (_activePlaylistSheet != null)
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                bottom: dockedHeight,
                child: TweenAnimationBuilder<double>(
                  key: ValueKey(_activePlaylistSheet!.id),
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: AppMotion.fast,
                  curve: AppMotion.standard,
                  builder: (context, t, child) => Opacity(
                    opacity: t,
                    child: Transform.translate(
                      offset: Offset(0, (1 - t) * 40),
                      child: child,
                    ),
                  ),
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: GestureDetector(
                          onTap: () =>
                              setState(() => _activePlaylistSheet = null),
                          child: const ColoredBox(color: AppColors.black45),
                        ),
                      ),
                      Align(
                        alignment: Alignment.bottomCenter,
                        child: PlaylistDetailSheet(
                          playlist: _activePlaylistSheet!,
                          onSelectTrack: _onPlayTrackAndExpand,
                          onPlayOnly: _onPlayTrackOnly,
                          onPlayCollection: _playCollection,
                          onPlaylistUpdated: _loadHistory,
                          onClose: () =>
                              setState(() => _activePlaylistSheet = null),
                        ),
                      ),
                    ],
                  ),
                ),
              ),


            // Layer 3: Permanent Docked MiniPlayer (Top of Z-index, ALWAYS interactive!)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: ListenableBuilder(
                key: _miniPlayerKey,
                listenable: Listenable.merge([_currentTrack, _isPlaying]),
                builder: (context, _) => MiniPlayer(
                currentTrack: _currentTrack.value,
                isPlaying: _isPlaying.value,
                positionNotifier: _positionNotifier,
                durationNotifier: _durationNotifier,
                onPlayPause: () {
                  if (_isPlaying.value) {
                    _audioHandler.pause();
                  } else {
                    _audioHandler.play();
                  }
                },
                onNext: _audioHandler.skipToNext,
                onPrevious: _audioHandler.skipToPrevious,
                onSeek: _audioHandler.seek,
                onTap: _openNowPlaying,
              ),
              ),
            ),
          ],
          ),
        ],
      ),
    );
  }
}
