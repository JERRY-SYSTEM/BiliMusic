import 'dart:async';

import 'package:audio_service/audio_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:just_audio/just_audio.dart' as ja;

import 'package:bilimusic/models/track.dart';
import 'package:bilimusic/models/lyric_line.dart';
import 'package:bilimusic/services/audio_player_handler.dart';

const first = Track(
  id: 'a', bvid: 'a', cid: 1, title: 'First', rawTitle: 'First',
  uploader: 'Artist', coverUrl: '', duration: 10,
);
const second = Track(
  id: 'b', bvid: 'b', cid: 2, title: 'Second', rawTitle: 'Second',
  uploader: 'Artist', coverUrl: '', duration: 10,
);
const third = Track(
  id: 'c', bvid: 'c', cid: 3, title: 'Third', rawTitle: 'Third',
  uploader: 'Artist', coverUrl: '', duration: 10,
);
const fourth = Track(
  id: 'd', bvid: 'd', cid: 4, title: 'Fourth', rawTitle: 'Fourth',
  uploader: 'Artist', coverUrl: '', duration: 10,
);
const fifth = Track(
  id: 'e', bvid: 'e', cid: 5, title: 'Fifth', rawTitle: 'Fifth',
  uploader: 'Artist', coverUrl: '', duration: 10,
);

/// Models just_audio's long-lived play Future and its playing=true at EOF.
/// The fake does not attach sources to a platform, so queue edits stay local.
class FakeAudioPlayer extends Fake implements ja.AudioPlayer {
  final states = StreamController<ja.PlayerState>.broadcast();
  final positions = StreamController<Duration>.broadcast();
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
  Stream<Duration> get positionStream => positions.stream;
  @override
  Stream<Duration?> get durationStream => const Stream.empty();
  @override
  Stream<int?> get currentIndexStream => const Stream.empty();
  @override
  Stream<ja.PlayerException> get errorStream => const Stream.empty();

  void emit() => states.add(ja.PlayerState(playing, processingState));

  void emitPosition(Duration value) {
    position = value;
    positions.add(value);
  }

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
    await positions.close();
  }
}

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAudioPlayer player;
  late BiliMusicAudioHandler handler;
  late List<String> downloads;
  late Map<String, Completer<String>> pendingDownloads;

  setUp(() {
    player = FakeAudioPlayer();
    downloads = [];
    pendingDownloads = {};
    handler = BiliMusicAudioHandler(
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
}
