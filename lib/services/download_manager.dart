import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/track.dart';
import 'audio_download_service.dart';

/// A live snapshot of an in-flight download.
///
/// There is no `status`: a task exists only while it is downloading, and is
/// removed on completion *or* failure. The old `DownloadStatus.failed` was
/// never assigned anywhere, so every `status == downloading` check in the app
/// was a tautology guarding unreachable state.
class DownloadTask {
  final Track track;

  /// 0..1, or 0 when the server sent no content length.
  final double fraction;

  const DownloadTask({required this.track, this.fraction = 0.0});

  DownloadTask copyWith({double? fraction}) =>
      DownloadTask(track: track, fraction: fraction ?? this.fraction);
}

/// Tracks user-initiated downloads with live progress so any screen can render
/// Apple Music–style rings and "X 下载中 / Y 已下载" counts.
///
/// Playback-path downloads (started inside the audio handler) are intentionally
/// NOT tracked here — only explicit user downloads are surfaced.
class DownloadManager {
  DownloadManager._() {
    AudioDownloadService.progressStream.listen(_onProgress);
  }
  static final DownloadManager instance = DownloadManager._();

  final Map<String, DownloadTask> _tasks = {};
  final StreamController<String> _controller = StreamController<String>.broadcast();
  final StreamController<String> _errorController = StreamController<String>.broadcast();

  /// Emits the id of the track whose download state changed, so listeners
  /// can compare against their own id and sleep through everyone else's
  /// downloads. (Previously every listener ran on every progress tick of
  /// every download; N visible rows meant N wake-ups per 64 KiB chunk.)
  Stream<String> get updates => _controller.stream;

  /// Emits a human-readable message when a user-initiated download fails —
  /// without this a failure was indistinguishable from a success (the ring
  /// simply disappeared).
  Stream<String> get errors => _errorController.stream;

  /// Currently in-flight tasks, newest first.
  List<DownloadTask> get activeTasks => _tasks.values.toList().reversed.toList();

  DownloadTask? taskFor(String trackId) => _tasks[trackId];

  bool isDownloading(String trackId) => _tasks.containsKey(trackId);

  /// Starts downloading [track] (idempotent). Observe progress via [updates].
  Future<void> startDownload(Track track) async {
    // Claim the slot synchronously, before any await. Checking `isDownloaded`
    // first meant two rapid taps could both clear the guard during that await
    // and start the same download twice.
    if (_tasks.containsKey(track.id)) return;
    _tasks[track.id] = DownloadTask(track: track);
    _notify(track.id);
    try {
      // ensureDownloaded is itself a no-op when the file is already on disk.
      await AudioDownloadService.ensureDownloaded(track);
    } catch (e) {
      debugPrint('Download failed: $e');
      if (!_errorController.isClosed) _errorController.add('$e');
    } finally {
      _tasks.remove(track.id);
      _notify(track.id);
    }
  }

  void _onProgress(DownloadProgress p) {
    final task = _tasks[p.trackId];
    if (task == null) {
      // Playback-path downloads are deliberately untracked, but their
      // completion still matters to the row showing that track. Relaying the
      // id here is what lets buttons drop their own subscription to the raw
      // chunk-frequency progress stream.
      if (p.done) _notify(p.trackId);
      return;
    }
    // Error events are preludes to startDownload's catch, which reports them.
    if (p.done || p.error != null) return;
    _tasks[p.trackId] = task.copyWith(fraction: p.fraction);
    _notify(p.trackId);
  }

  void _notify(String trackId) {
    if (!_controller.isClosed) _controller.add(trackId);
  }
}
