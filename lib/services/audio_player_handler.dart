import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart' as ja;

import '../models/track.dart';
import 'audio_download_service.dart';
import 'database_service.dart';

enum LoopMode { off, all, one }

/// Playback engine built on a native just_audio queue.
///
/// Architecture (download-then-play):
///  * Every track is fully downloaded to disk before it plays; the native
///    player (ExoPlayer on Android, AVPlayer on iOS) reads the local file
///    directly. No loopback proxy, no Dart byte-forwarding, no ATS issues.
///  * A [ja.Playlist] holds a small window of downloaded files
///    so the OS can transition to the next track gaplessly. The next track is
///    pre-downloaded in the background as soon as the current one starts.
///  * Loop/shuffle/advance logic lives in Dart; the native queue is only a
///    sliding window that mirrors the logical playlist around [_currentIndex].
class BiliBeatAudioHandler extends BaseAudioHandler with SeekHandler {
  final ja.AudioPlayer _player = ja.AudioPlayer();
  // ignore: deprecated_member_use
  final ja.ConcatenatingAudioSource _queueSource =
      // ignore: deprecated_member_use
      ja.ConcatenatingAudioSource(children: []);

  /// The playlist in the order it is currently played (shuffled or not).
  final List<Track> _playlist = [];

  /// The playlist in its natural order, kept so turning shuffle off restores
  /// exactly what the user had before.
  final List<Track> _naturalOrder = [];

  int _currentIndex = -1;

  /// Logical playlist index of `_queueSource` child 0. Player index `i`
  /// therefore maps to logical index `_queueBaseIndex + i`.
  int _queueBaseIndex = 0;

  bool _isPlaying = false;
  LoopMode _loopMode = LoopMode.all;
  bool _isShuffle = false;
  bool _isRebuilding = false;
  String? _prefetchingId;

  /// Number of open surfaces that have asked playback not to move on by itself
  /// (the lyrics panel and the 信息/歌词 editor). A counter rather than a flag
  /// so the editor closing over the lyrics panel does not release the panel's
  /// hold. Repeat-one is unaffected — it repeats the same track, which is what
  /// the user asked for in that mode.
  int _autoAdvanceHolds = 0;

  /// Guards against overlapping [_startCurrent] runs when the user taps
  /// next/previous faster than a track can be prepared.
  int _startToken = 0;

  final StreamController<Track?> _currentTrackController =
      StreamController<Track?>.broadcast();
  final StreamController<bool> _playerStateController =
      StreamController<bool>.broadcast();
  final StreamController<Duration> _positionController =
      StreamController<Duration>.broadcast();
  final StreamController<Duration> _durationController =
      StreamController<Duration>.broadcast();
  final StreamController<bool> _shuffleController =
      StreamController<bool>.broadcast();
  final StreamController<LoopMode> _loopModeController =
      StreamController<LoopMode>.broadcast();

  Duration _duration = Duration.zero;

  Stream<Track?> get currentTrackStream => _currentTrackController.stream;
  Stream<bool> get playerStateStream => _playerStateController.stream;
  Stream<Duration> get positionStream => _positionController.stream;
  Stream<Duration> get durationStream => _durationController.stream;
  Stream<bool> get shuffleStream => _shuffleController.stream;
  Stream<LoopMode> get loopModeStream => _loopModeController.stream;

  Track? get currentTrack =>
      (_currentIndex >= 0 && _currentIndex < _playlist.length)
          ? _playlist[_currentIndex]
          : null;
  bool get isPlaying => _isPlaying;
  LoopMode get loopMode => _loopMode;
  bool get isShuffle => _isShuffle;

  BiliBeatAudioHandler() {
    _initAudioPlayerListeners();
  }

  bool get autoAdvanceHeld => _autoAdvanceHolds > 0 && _loopMode != LoopMode.one;

  /// Stops the queue from moving on when the current track ends, until the
  /// returned callback is invoked. The native queue is trimmed as well, since
  /// a prefetched next track would otherwise start gaplessly without ever
  /// reaching [_handleQueueCompleted].
  VoidCallback holdAutoAdvance() {
    _autoAdvanceHolds++;
    if (_autoAdvanceHolds == 1) unawaited(_trimQueueAfterCurrent());
    var released = false;
    return () {
      if (released) return;
      released = true;
      _autoAdvanceHolds--;
      if (_autoAdvanceHolds == 0 && _loopMode != LoopMode.one) {
        unawaited(_prefetchNext());
      }
    };
  }

  void updateCurrentTrackMetadata(Track updatedTrack) {
    var changed = false;
    for (final list in [_playlist, _naturalOrder]) {
      final idx = list.indexWhere((t) => t.id == updatedTrack.id);
      if (idx != -1) {
        list[idx] = updatedTrack;
        changed = true;
      }
    }
    if (!changed) return;
    if (currentTrack?.id == updatedTrack.id) {
      _currentTrackController.add(updatedTrack);
      _updateMediaItem(updatedTrack);
    }
  }


  void _initAudioPlayerListeners() {
    // Position is forwarded to the UI only. We deliberately do NOT broadcast
    // playback state here: pushing a PlaybackState to audio_service on every
    // tick causes notification/MediaSession churn. The system UI interpolates
    // the notification position from the last state + speed.
    _player.positionStream.listen(_positionController.add);

    _player.durationStream.listen((dur) {
      if (dur != null && dur > Duration.zero) {
        _duration = dur;
        _durationController.add(dur);
        _broadcastState();
      }
    });

    _player.playerStateStream.listen((state) {
      _isPlaying = state.playing;
      _playerStateController.add(_isPlaying);
      _broadcastState();

      if (state.processingState == ja.ProcessingState.completed) {
        _handleQueueCompleted();
      }
    });

    // Fires when the native player advances to the next queued file (gapless
    // auto-advance). Reconcile our logical index and prepare the following one.
    _player.currentIndexStream.listen((playerIndex) {
      if (playerIndex == null) return;
      // While a start is in flight the native queue still holds the *previous*
      // track, so `_queueBaseIndex` does not describe it: mapping an index
      // through it would announce — and then actually play — some unrelated
      // track. This is what made tapping a song in 最近播放 occasionally start
      // a different one: clearing and re-setting the audio source emits index
      // events, and the stale base index turned them into a bogus logical
      // position.
      if (_isRebuilding) return;
      final logical = _queueBaseIndex + playerIndex;
      // Guard against echoes from rebuilds / no-op changes.
      if (logical == _currentIndex) return;
      if (logical < 0 || logical >= _playlist.length) return;
      _currentIndex = logical;
      _onActiveTrackChanged(_playlist[logical]);
    });
  }

  /// Called whenever the actively-playing track changes (manual or auto).
  void _onActiveTrackChanged(Track track) {
    _announce(track);
    _prefetchNext();
  }

  /// Re-syncs the announced track with the platform player's ACTUAL position.
  ///
  /// The platform can move ahead of the logical index while `_isRebuilding` is
  /// up: the old window's next item starts gaplessly, or just_audio's Android
  /// implementation auto-advances (`seekToNextMediaItem`) when a child is
  /// appended while the player is in STATE_ENDED with playWhenReady still true.
  /// Those index events are deliberately dropped by the guards in
  /// [currentIndexStream]'s listener, and nothing then re-announces the track
  /// that is really playing — the card keeps showing `_playlist[_currentIndex]`
  /// (the old song) while the audio moves on.
  ///
  /// Runs after every rebuild settles (and after re-anchoring the window), and
  /// only ever announces when the mapping is provably correct: the queue's
  /// current child's tag must be the very track `_playlist[logical]` says it
  /// is. During a failed start the base index can still describe the previous
  /// window, so without this tag check a bogus announce could land on some
  /// unrelated track of the new playlist.
  void _reconcileActiveTrack() {
    final playerIndex = _player.currentIndex;
    if (playerIndex == null || playerIndex < 0) return;
    if (playerIndex >= _queueSource.length) return;
    final logical = _queueBaseIndex + playerIndex;
    if (logical < 0 || logical >= _playlist.length) return;
    if (logical == _currentIndex) return;
    final queuedChild = _queueSource.children[playerIndex];
    if (queuedChild is! ja.IndexedAudioSource) return;
    final queuedTag = queuedChild.tag;
    if (queuedTag is! Track) return;
    if (queuedTag.id != _playlist[logical].id) return;
    _currentIndex = logical;
    _onActiveTrackChanged(_playlist[logical]);
  }

  /// Announce the newly active track to every observer: the UI stream, the
  /// system media session, the recently-played history and the duration.
  void _announce(Track track) {
    _currentTrackController.add(track);
    _updateMediaItem(track);
    unawaited(DatabaseService.addRecentlyPlayed(track));
    _duration = Duration(seconds: track.duration > 0 ? track.duration : 180);
    _durationController.add(_duration);
    _broadcastState();
  }

  // ---------------------------------------------------------------------------
  // Public playback API
  // ---------------------------------------------------------------------------

  Future<void> playTrack(Track track, {List<Track>? newQueue}) async {
    if (newQueue != null && newQueue.isNotEmpty) {
      _naturalOrder
        ..clear()
        ..addAll(newQueue);
      _playlist
        ..clear()
        ..addAll(newQueue);
      if (_isShuffle) _applyShuffleOrder(pinned: track);
    }
    if (!_playlist.any((t) => t.id == track.id)) {
      _playlist.insert(0, track);
      _naturalOrder.insert(0, track);
    }

    var index = _playlist.indexWhere((t) => t.id == track.id);
    if (index == -1) index = 0;
    _currentIndex = index;

    // Announce immediately so the UI updates while the file downloads.
    final active = _playlist[index];
    _announce(active);
    _positionController.add(Duration.zero);

    await _startCurrent(autoplay: true);
  }

  @override
  Future<void> play() async {
    // Cold restore: we have a logical track but an empty native queue.
    if (_queueSource.length == 0 && currentTrack != null) {
      await _startCurrent(autoplay: true);
      return;
    }
    // Nothing loaded at all: playing would be a lie the UI then renders as
    // a paused-state toggle for silence. Stand down instead.
    if (_queueSource.length == 0) return;
    await _player.play();
    _isPlaying = true;
    _playerStateController.add(true);
    _broadcastState();
  }

  @override
  Future<void> pause() async {
    await _player.pause();
    _isPlaying = false;
    _playerStateController.add(false);
    _broadcastState();
  }

  @override
  Future<void> stop() async {
    await _player.stop();
    _isPlaying = false;
    _playerStateController.add(false);
    _broadcastState();
    await super.stop();
  }

  @override
  Future<void> seek(Duration position) async {
    await _player.seek(position);
    _positionController.add(position);
    _broadcastState();
  }

  @override
  Future<void> skipToNext() async {
    if (_playlist.isEmpty) return;

    // An explicit "next" always advances, even in repeat-one — matching every
    // mainstream player. Repeat-one only governs *automatic* advance.
    if (_player.hasNext && _loopMode != LoopMode.one) {
      // Gapless: the next file is already queued in the native player.
      await _player.seekToNext();
      return;
    }

    final next = _currentIndex + 1;
    if (next < _playlist.length) {
      await _playAtIndex(next);
    } else if (_loopMode != LoopMode.off) {
      await _playAtIndex(0);
    } else {
      await seek(Duration.zero);
      await pause();
    }
  }

  @override
  Future<void> skipToPrevious() async {
    if (_playlist.isEmpty) return;

    // Standard music UX: restart the current track once we're >3s in.
    if (_player.position > const Duration(seconds: 3)) {
      await seek(Duration.zero);
      return;
    }

    final prev = _currentIndex - 1;
    if (prev >= 0) {
      await _playAtIndex(prev);
    } else if (_loopMode != LoopMode.off) {
      await _playAtIndex(_playlist.length - 1);
    } else {
      await seek(Duration.zero);
    }
  }

  @override
  Future<void> skipToQueueItem(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    await _playAtIndex(index);
  }

  /// Switch to a logical index and start it, reusing the native queue when the
  /// target is already the prefetched next item (so the transition is gapless).
  Future<void> _playAtIndex(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    final playerIndex = index - _queueBaseIndex;
    if (playerIndex >= 0 && playerIndex < _queueSource.length) {
      _currentIndex = index;
      // Broadcast immediately: the currentIndexStream listener's
      // `logical == _currentIndex` guard would swallow the echo from the
      // seek below, so without this the UI never learns the track changed.
      _positionController.add(Duration.zero);
      _onActiveTrackChanged(_playlist[index]);
      await _player.seek(Duration.zero, index: playerIndex);
      if (!_isPlaying) await _player.play();
      return;
    }
    _currentIndex = index;
    final active = _playlist[index];
    _announce(active);
    _positionController.add(Duration.zero);
    await _startCurrent(autoplay: true);
  }

  /// Cycle the single play-mode control: 列表循环 -> 单曲循环 -> 随机 -> 列表循环.
  Future<void> cyclePlayMode() async {
    if (_isShuffle) {
      await setShuffle(false);
      await setLoopMode(LoopMode.all);
    } else if (_loopMode != LoopMode.one) {
      await setLoopMode(LoopMode.one);
    } else {
      await setLoopMode(LoopMode.all);
      await setShuffle(true);
    }
  }

  Future<void> setLoopMode(LoopMode mode) async {
    if (_loopMode == mode) return;
    _loopMode = mode;
    _loopModeController.add(_loopMode);
    // just_audio's LoopMode.one repeats the *current* item of the queue, so no
    // rebuild is needed — the playing track keeps its position.
    await _player.setLoopMode(
      mode == LoopMode.one ? ja.LoopMode.one : ja.LoopMode.off,
    );
    if (mode == LoopMode.one) {
      // Nothing beyond the current item should auto-play.
      await _trimQueueAfterCurrent();
    } else {
      unawaited(_prefetchNext());
    }
    _broadcastState();
  }

  Future<void> setShuffle(bool on) async {
    if (_isShuffle == on) return;
    _isShuffle = on;
    _shuffleController.add(_isShuffle);
    if (_playlist.isEmpty) return;

    final current = currentTrack;
    if (on) {
      _applyShuffleOrder(pinned: current);
    } else {
      _playlist
        ..clear()
        ..addAll(_naturalOrder);
    }
    _currentIndex = current == null
        ? -1
        : _playlist.indexWhere((t) => t.id == current.id);
    if (_currentIndex < 0) _currentIndex = 0;

    // Re-anchor the native window on the still-playing item and re-prefetch,
    // without ever touching playback of the current track.
    final playerIndex = _player.currentIndex ?? 0;
    _queueBaseIndex = _currentIndex - playerIndex;
    await _trimQueueAfterCurrent();
    _reconcileActiveTrack();
    unawaited(_prefetchNext());
  }

  /// Reorders [_playlist] randomly, keeping [pinned] where it is so the
  /// currently-playing track is never yanked out from under playback.
  void _applyShuffleOrder({Track? pinned}) {
    final others =
        _naturalOrder.where((t) => t.id != pinned?.id).toList()..shuffle();
    _playlist
      ..clear()
      ..addAll([if (pinned != null) pinned, ...others]);
  }

  // ---------------------------------------------------------------------------
  // Internals
  // ---------------------------------------------------------------------------

  /// Drops every queued item after the one the player is currently on, so the
  /// prefetch window can be rebuilt without interrupting playback.
  Future<void> _trimQueueAfterCurrent() async {
    final playerIndex = _player.currentIndex ?? 0;
    if (_queueSource.length > playerIndex + 1) {
      await _queueSource.removeRange(playerIndex + 1, _queueSource.length);
    }
    _prefetchingId = null;
  }

  /// Download (if needed) the current track and load it as a single-item native
  /// queue, then optionally start playback and prefetch the following track.
  Future<void> _startCurrent({required bool autoplay}) async {
    final active = currentTrack;
    if (active == null) return;

    final token = ++_startToken;
    _broadcastState(processingOverride: AudioProcessingState.loading);

    // Set *before* the download await, not just around the queue rebuild: from
    // here until the new source is installed, the native queue and the logical
    // index disagree, and anything that reconciles them (index events, queue
    // completion) has to stand down. Downloading a track can take seconds —
    // that was a wide-open window for the old track to finish and advance the
    // logical playlist out from under this start.
    _isRebuilding = true;

    final String path;
    try {
      path = await AudioDownloadService.ensureDownloaded(active);
    } catch (e) {
      debugPrint('playTrack download failed: $e');
      if (token == _startToken) {
        _isRebuilding = false;
        // The start never landed: announce whatever the platform is really
        // playing (the old window may have advanced while we downloaded), so
        // the card does not stay stuck on a track that never started.
        _reconcileActiveTrack();
        // On a cold start there is no source at all (currentIndex == null),
        // so the reconcile above announces nothing — re-broadcast the real
        // state to unpin the media session from the loading state pushed at
        // the top of this method.
        _broadcastState();
      }
      return;
    }
    // A newer start won the race while we were downloading — drop this one.
    // Its own run owns `_isRebuilding` now, so leave the flag alone.
    if (token != _startToken) return;

    try {
      await _queueSource.clear();
      await _queueSource.add(ja.AudioSource.file(path, tag: active));
      _queueBaseIndex = _currentIndex;
      _prefetchingId = null;

      await _player.setLoopMode(
        _loopMode == LoopMode.one ? ja.LoopMode.one : ja.LoopMode.off,
      );
      await _player.setAudioSource(
        _queueSource,
        initialIndex: 0,
        initialPosition: Duration.zero,
      );

      if (autoplay && token == _startToken) {
        await _player.play();
        _isPlaying = true;
        _playerStateController.add(true);
      }
    } catch (e) {
      debugPrint('startCurrent error: $e');
    } finally {
      // Again: only the newest start may lower the flag.
      if (token == _startToken) {
        _isRebuilding = false;
        // Re-sync the announced track with the platform's real position (see
        // [_reconcileActiveTrack]).
        _reconcileActiveTrack();
      }
    }

    if (token != _startToken) return;
    _broadcastState();
    if (_loopMode != LoopMode.one) unawaited(_prefetchNext());
  }

  /// Background-download the next logical track and append it to the native
  /// queue, but only when it is the immediate contiguous successor of the
  /// queue's last child. This keeps the window gapless-ready without ever
  /// streaming bytes through Dart.
  Future<void> _prefetchNext() async {
    if (_loopMode == LoopMode.one || autoAdvanceHeld) return;
    if (_playlist.isEmpty || _currentIndex < 0) return;

    // Only the contiguous successor is prefetched: the window's player index
    // must stay a simple offset from the logical index. Wrapping past the end
    // is handled by [_handleQueueCompleted] instead.
    final nextIndex = _currentIndex + 1;
    if (nextIndex >= _playlist.length) return;

    final next = _playlist[nextIndex];
    if (_prefetchingId == next.id) return;

    // Only append when the current track is the last thing queued, so player
    // index stays a simple offset from the logical index.
    if (_currentIndex != _queueBaseIndex + _queueSource.length - 1) return;

    _prefetchingId = next.id;
    try {
      final path = await AudioDownloadService.ensureDownloaded(next);
      // Re-validate after the download: the user may have navigated, or the
      // playlist may have been replaced while we were fetching — the index
      // guard alone can pass for a *new* window and append a stale track.
      final succIndex = _currentIndex + 1;
      if (_currentIndex == _queueBaseIndex + _queueSource.length - 1 &&
          succIndex < _playlist.length &&
          _playlist[succIndex].id == next.id) {
        await _queueSource.add(ja.AudioSource.file(path, tag: next));
      }
    } catch (e) {
      debugPrint('Prefetch next track error: $e');
    } finally {
      if (_prefetchingId == next.id) _prefetchingId = null;
    }
  }

  /// The native queue ran out. Advance the logical playlist (the prefetch of
  /// the following track may simply not have finished in time).
  void _handleQueueCompleted() {
    if (_isRebuilding || _playlist.isEmpty) return;

    // The user is on the lyrics / info surface: end here rather than pulling
    // the ground out from under them by loading another track.
    if (autoAdvanceHeld) {
      _isPlaying = false;
      _playerStateController.add(false);
      _broadcastState();
      return;
    }

    final next = _currentIndex + 1;
    if (next < _playlist.length) {
      _playAtIndex(next);
      return;
    }
    if (_loopMode == LoopMode.all) {
      _playAtIndex(0);
      return;
    }
    _isPlaying = false;
    _playerStateController.add(false);
    _broadcastState();
  }

  void _broadcastState({AudioProcessingState? processingOverride}) {
    final playing = _player.playing;
    final mapped = const {
      ja.ProcessingState.idle: AudioProcessingState.idle,
      ja.ProcessingState.loading: AudioProcessingState.loading,
      ja.ProcessingState.buffering: AudioProcessingState.buffering,
      ja.ProcessingState.ready: AudioProcessingState.ready,
      ja.ProcessingState.completed: AudioProcessingState.completed,
    }[_player.processingState];

    playbackState.add(PlaybackState(
      controls: [
        MediaControl.skipToPrevious,
        if (playing) MediaControl.pause else MediaControl.play,
        MediaControl.skipToNext,
      ],
      systemActions: const {
        MediaAction.seek,
        MediaAction.seekForward,
        MediaAction.seekBackward,
      },
      androidCompactActionIndices: const [0, 1, 2],
      processingState: processingOverride ?? mapped ?? AudioProcessingState.idle,
      playing: playing,
      updatePosition: _player.position,
      bufferedPosition: _player.bufferedPosition,
      speed: _player.speed,
      repeatMode: _loopMode == LoopMode.one
          ? AudioServiceRepeatMode.one
          : (_loopMode == LoopMode.all
              ? AudioServiceRepeatMode.all
              : AudioServiceRepeatMode.none),
      shuffleMode: _isShuffle
          ? AudioServiceShuffleMode.all
          : AudioServiceShuffleMode.none,
      queueIndex: _currentIndex >= 0 ? _currentIndex : null,
    ));
  }

  void _updateMediaItem(Track track) {
    final item = MediaItem(
      id: track.id,
      album: 'BiliBeat',
      title: track.title,
      artist: track.uploader,
      duration: Duration(seconds: track.duration > 0 ? track.duration : 180),
      artUri: track.coverUrl.isEmpty ? null : Uri.tryParse(track.coverUrl),
    );
    mediaItem.add(item);
  }
}
