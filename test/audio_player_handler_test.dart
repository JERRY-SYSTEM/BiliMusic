import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/services/audio_player_handler.dart';

const first = Track(
  id: 'a', bvid: 'a', cid: 1, title: 'First', rawTitle: 'First',
  uploader: 'Artist', coverUrl: '', duration: 10,
);
const second = Track(
  id: 'b', bvid: 'b', cid: 2, title: 'Second', rawTitle: 'Second',
  uploader: 'Artist', coverUrl: '', duration: 10,
);

/// Models just_audio's long-lived play Future and its playing=true at EOF.
/// The fake does not attach sources to a platform, so queue edits stay local.
class FakeAudioPlayer extends Fake implements ja.AudioPlayer {
  final states = StreamController<ja.PlayerState>.broadcast();
  Completer<void>? playback;
  ja.AudioSource? source;

  @override
  bool playing = false;
  @override
  ja.ProcessingState processingState = ja.ProcessingState.idle;
  @override
  int? currentIndex;
  @override
  Duration position = Duration.zero;
  @override
  Duration get bufferedPosition => position;
  @override
  double get speed => 1;
  @override
  Stream<ja.PlayerState> get playerStateStream => states.stream;
  @override
  Stream<Duration> get positionStream => const Stream.empty();
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<ja.PlayerException> get errorStream => const Stream.empty();

  void emit() => states.add(ja.PlayerState(playing, processingState));

  @override
  Future<Duration?> setAudioSource(ja.AudioSource source, {
    bool preload = true, int? initialIndex, Duration? initialPosition,
  }) async {
    this.source = source;
    currentIndex = initialIndex ?? 0;
    position = initialPosition ?? Duration.zero;
    processingState = ja.ProcessingState.ready;
    emit();
    return const Duration(seconds: 10);
  }

  @override
  Future<void> setLoopMode(ja.LoopMode mode) async {}

  @override
  Future<void> play() {
    if (playing) return Future.value();
    playback = Completer<void>();
    playing = true;
    emit();
    return playback!.future;
  }

  @override
  Future<void> pause() async {
    playing = false;
    emit();
    finishPlayFuture();
  }

  @override
  Future<void> stop() => pause();

  @override
  Future<void> seek(Duration? position, {int? index}) async {
    this.position = position ?? Duration.zero;
    if (index != null) currentIndex = index;
    processingState = ja.ProcessingState.ready;
    emit();
  }

  void finishPlayFuture() {
    final pending = playback;
    if (pending != null && !pending.isCompleted) pending.complete();
  }

  void completeTrack() {
    position = const Duration(seconds: 10);
    processingState = ja.ProcessingState.completed;
    // Completion is delivered before play() resolves, as on native players.
    emit();
    finishPlayFuture();
  }

  @override
  Future<void> dispose() async {
    finishPlayFuture();
    await states.close();
  }
}

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAudioPlayer player;
  late BiliBeatAudioHandler handler;
  late List<String> downloads;
  late Map<String, Completer<String>> pendingDownloads;

  setUp(() {
    player = FakeAudioPlayer();
    downloads = [];
    pendingDownloads = {};
    handler = BiliBeatAudioHandler(
      player: player,
      ensureDownloaded: (track) async {
        downloads.add(track.id);
        final pending = pendingDownloads[track.id];
        if (pending != null) return pending.future;
        return '${track.id}.m4a';
      },
    );
  });

  tearDown(() async {
    await handler.clearQueue();
    await handler.persistPlaybackState();
    await player.dispose();
  });

  test('start returns and prefetch runs while play Future is pending', () async {
    await handler.playTrack(first, newQueue: [first, second])
        .timeout(const Duration(seconds: 1));
    await flushEvents();

    expect(player.playback!.isCompleted, isFalse);
    expect(downloads, contains(second.id));
    // ignore: deprecated_member_use
    expect((player.source as ja.ConcatenatingAudioSource).length, 2);
    expect(handler.isPlaying, isTrue);
  });

  test('EOF advances without prefetch in shuffle mode', () async {
    await handler.setShuffle(true);
    await handler.playTrack(first, newQueue: [first, second])
        .timeout(const Duration(seconds: 1));

    player.completeTrack();
    await flushEvents();

    expect(handler.currentTrack?.id, second.id);
    expect(player.processingState, ja.ProcessingState.ready);
    expect(handler.playbackState.value.playing, isTrue);
  });

  test('EOF waits for a slow next download then starts that track', () async {
    final nextDownload = Completer<String>();
    pendingDownloads[second.id] = nextDownload;
    await handler.playTrack(first, newQueue: [first, second])
        .timeout(const Duration(seconds: 1));

    player.completeTrack();
    await flushEvents();
    expect(handler.currentTrack?.id, second.id);
    expect(handler.playbackState.value.processingState,
        AudioProcessingState.loading);

    nextDownload.complete('b.m4a');
    await flushEvents();
    expect(handler.currentTrack?.id, second.id);
    expect(player.processingState, ja.ProcessingState.ready);
    expect(handler.isPlaying, isTrue);
  });

  test('list repeat wraps from the final track back to the first', () async {
    await handler.playTrack(second, newQueue: [first, second])
        .timeout(const Duration(seconds: 1));
    player.completeTrack();
    await flushEvents();

    expect(handler.currentTrack?.id, first.id);
    expect(player.processingState, ja.ProcessingState.ready);
    expect(handler.isPlaying, isTrue);
  });

  test('pause cannot be overwritten by completion of play Future', () async {
    await handler.playTrack(first).timeout(const Duration(seconds: 1));
    await handler.pause();
    await flushEvents();

    expect(handler.isPlaying, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
    await handler.play().timeout(const Duration(seconds: 1));
    await flushEvents();
    expect(handler.isPlaying, isTrue);
  });

  test('held EOF reports stopped consistently and play restarts it', () async {
    final release = handler.holdAutoAdvance();
    await handler.playTrack(first, newQueue: [first, second])
        .timeout(const Duration(seconds: 1));
    player.completeTrack();
    await flushEvents();

    expect(handler.currentTrack?.id, first.id);
    expect(handler.isPlaying, isFalse);
    expect(handler.playbackState.value.playing, isFalse);
    expect(handler.playbackState.value.controls, contains(MediaControl.play));
    await handler.play().timeout(const Duration(seconds: 1));
    await flushEvents();
    expect(player.position, Duration.zero);
    expect(handler.isPlaying, isTrue);
    release();
    await flushEvents();
  });
}
