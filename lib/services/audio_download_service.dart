import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'bili_http.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';

/// Immutable snapshot of a single track download's progress.
class DownloadProgress {
  final String trackId;
  final int receivedBytes;
  final int? totalBytes;
  final bool done;
  final String? error;

  const DownloadProgress(
    this.trackId,
    this.receivedBytes,
    this.totalBytes,
    this.done,
    this.error,
  );

  double get fraction {
    final total = totalBytes;
    if (total == null || total <= 0) return 0.0;
    return (receivedBytes / total).clamp(0.0, 1.0);
  }
}

/// Downloads Bilibili audio to disk so playback is always served from a local
/// file. The native player (ExoPlayer / AVPlayer) reads straight from disk with
/// zero extra hops, no Dart-isolate byte forwarding, and no cleartext/ATS
/// issues on iOS.
///
/// Files are keyed by the full track id (`bvid_cid`), which uniquely identifies
/// a single playable part. Keying by `bvid` alone would collide across the
/// parts (P1/P2/…) of a multi-part video and play the wrong audio.
class AudioDownloadService {
  AudioDownloadService._();

  static final HttpClient _client = biliHttpClient(
    connectionTimeout: const Duration(seconds: 15),
    idleTimeout: const Duration(seconds: 60),
  );

  static String? _dirPath;

  /// Deduplicates concurrent downloads of the same track.
  static final Map<String, Future<String>> _inFlight = {};

  static final StreamController<DownloadProgress> _progressController =
      StreamController<DownloadProgress>.broadcast();

  /// Broadcast stream of download progress events (throttled per chunk batch).
  static Stream<DownloadProgress> get progressStream =>
      _progressController.stream;

  static Future<String> _dir() async {
    final cached = _dirPath;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    final path = '${docs.path}/bilibeat_audio';
    final dir = Directory(path);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _dirPath = path;
    return path;
  }

  /// Stable per-part key. Falls back to bvid only for the (rare) track built
  /// without a usable id.
  static String _key(Track track) =>
      track.id.isNotEmpty ? track.id : track.bvid;

  static String _audioPath(String dir, String key) => '$dir/audio_$key.m4a';
  static String _readyPath(String dir, String key) => '$dir/audio_$key.ready';
  static String _metaPath(String dir, String key) => '$dir/audio_$key.json';

  /// Saves track metadata JSON next to the audio file (used for rediscovery).
  ///
  /// Playback calls this on every start, with whatever `Track` object the
  /// caller happens to be holding — which may predate an edit the user made in
  /// 信息与歌词. Writing that unconditionally silently reverted the edit on
  /// disk, so by default this only *creates* the file. Deliberate edits pass
  /// [force] to overwrite.
  static Future<void> saveTrackMetadata(Track track,
      {bool force = false}) async {
    try {
      final dir = await _dir();
      final metaFile = File(_metaPath(dir, _key(track)));
      if (!force && await metaFile.exists()) return;
      final encoded = jsonEncode(track.toMap());
      if (await metaFile.exists() && await metaFile.readAsString() == encoded) {
        return;
      }
      await metaFile.writeAsString(encoded);
    } catch (e) {
      debugPrint('saveTrackMetadata error: $e');
    }
  }

  /// Memoised answers for [isDownloadedById].
  ///
  /// Every row of every list asks this on build, and each answer costs three
  /// filesystem round-trips — a screenful of search results was ~90 stat calls
  /// for a set of files only this class ever creates or removes. It is
  /// therefore safe to remember: the map is updated wherever the on-disk state
  /// changes (a completed download, a delete), so it cannot go stale except by
  /// something outside the app deleting files under us.
  static final Map<String, bool> _downloadedMemo = {};

  /// Bounds for the memo: every search row ever queried would otherwise
  /// accumulate for the whole app lifetime.
  static const int _memoCap = 1024;

  /// True when a complete, verified audio file exists on disk for [track].
  static Future<bool> isDownloaded(Track track) => isDownloadedById(_key(track));

  /// String-id variant of [isDownloaded] for callers that only hold an id.
  static Future<bool> isDownloadedById(String id) async {
    final memo = _downloadedMemo[id];
    if (memo != null) return memo;
    final result = await _statDownloaded(id);
    _downloadedMemo[id] = result;
    if (_downloadedMemo.length > _memoCap) {
      _downloadedMemo.remove(_downloadedMemo.keys.first);
    }
    return result;
  }

  static Future<bool> _statDownloaded(String id) async {
    final dir = await _dir();
    final audio = File(_audioPath(dir, id));
    final ready = File(_readyPath(dir, id));
    if (!await ready.exists()) return false;
    if (!await audio.exists()) return false;
    return await audio.length() > 0;
  }

  /// Removes a track's audio, ready-marker and metadata from disk.
  /// Returns true when something was actually deleted.
  static Future<bool> delete(Track track) async {
    final dir = await _dir();
    final id = _key(track);
    var deleted = false;
    for (final path in [
      _readyPath(dir, id),
      _audioPath(dir, id),
      _metaPath(dir, id),
      '${_audioPath(dir, id)}.part',
    ]) {
      final file = File(path);
      try {
        if (await file.exists()) {
          await file.delete();
          deleted = true;
        }
      } catch (e) {
        debugPrint('delete download error: $e');
      }
    }
    _downloadedMemo[id] = false;
    return deleted;
  }

  /// Ensures [track]'s audio is fully downloaded and returns the local path.
  ///
  /// Idempotent and concurrency-safe: a second call for the same track while a
  /// download is in flight awaits the same future instead of downloading twice.
  static Future<String> ensureDownloaded(Track track) async {
    final dir = await _dir();
    final id = _key(track);
    final path = _audioPath(dir, id);
    await saveTrackMetadata(track);
    // Already on disk: no DB write either — registration happens at download
    // time (below) and at library load, so replaying every track start would
    // just be an O(n) scan over the library for nothing.
    if (await isDownloadedById(id)) {
      return path;
    }

    final existing = _inFlight[id];
    if (existing != null) return existing;

    final future = _download(track, dir, path);
    _inFlight[id] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(id);
    }
  }

  static Future<String> _download(Track track, String dir, String path) async {
    var url = track.audioUrl;
    if (url == null || url.isEmpty) {
      final info = await BilibiliSdk.fetchAudioStream(track.bvid, track.cid);
      url = info?['url'];
    }
    if (url == null || url.isEmpty) {
      _emit(DownloadProgress(track.id, 0, null, false, '无法获取音源下载链接'));
      throw Exception('无法获取音源下载链接');
    }

    final tmp = File('$path.part');
    IOSink? sink;
    var lastEmitted = 0;
    try {
      final req = await _client.getUrl(Uri.parse(url));
      req.headers.set('Referer', 'https://www.bilibili.com/');
      req.headers.set('User-Agent', kBiliUserAgent);
      req.headers.set('Accept', '*/*');
      req.headers.set('Accept-Encoding', 'identity');

      // Resume an interrupted download when a .part file survived: ask for
      // the remaining range. A server that ignores Range answers 200 with
      // the whole file, which is detected below and starts from scratch.
      final existing = await tmp.exists() ? await tmp.length() : 0;
      if (existing > 0) {
        req.headers.set('Range', 'bytes=$existing-');
      }

      final res = await req.close();
      // A .part that already covers the whole file (e.g. a crash between the
      // rename and the .ready marker) makes the CDN answer 416. The bytes on
      // disk are complete — finalize them instead of failing the download.
      if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existing > 0) {
        await res.drain<void>();
        final destination = File(path);
        if (await destination.exists()) {
          await destination.delete();
        }
        await tmp.rename(path);
        await File(_readyPath(dir, _key(track))).create();
        await saveTrackMetadata(track);
        _downloadedMemo[_key(track)] = true;
        _emit(DownloadProgress(track.id, existing, existing, true, null));
        await DatabaseService.saveDownloadedTrack(track);
        return path;
      }
      if (res.statusCode != HttpStatus.ok &&
          res.statusCode != HttpStatus.partialContent) {
        await res.drain<void>();
        throw Exception('CDN HTTP ${res.statusCode}');
      }
      // A signed CDN link that has expired answers 200 with an HTML/JSON error
      // body; writing that to disk would leave a permanently "downloaded"
      // track that cannot play.
      final contentType = res.headers.contentType?.mimeType ?? '';
      if (contentType.startsWith('text/') || contentType.contains('json')) {
        await res.drain<void>();
        throw Exception('CDN 返回了非音频内容 ($contentType)');
      }

      final int? total;
      var received = 0;
      if (res.statusCode == HttpStatus.partialContent) {
        // 206: the server honored the range — append to what is on disk.
        received = existing;
        lastEmitted = existing;
        total = res.contentLength > 0 ? existing + res.contentLength : null;
        sink = tmp.openWrite(mode: FileMode.append);
      } else {
        // 200 after a Range request means the server ignored it; the body is
        // the entire file, so whatever the .part holds is unusable.
        if (existing > 0) {
          await tmp.delete();
        }
        total = res.contentLength > 0 ? res.contentLength : null;
        sink = tmp.openWrite();
      }

      await for (final chunk in res) {
        sink.add(chunk);
        received += chunk.length;
        // Throttle progress events to ~every 64 KiB to avoid stream spam.
        if (received - lastEmitted >= 65536) {
          lastEmitted = received;
          _emit(DownloadProgress(track.id, received, total, false, null));
        }
      }

      await sink.flush();
      await sink.close();
      sink = null;

      // Truncated transfer (dropped connection mid-stream): fail loudly rather
      // than marking a half file as ready.
      if (total != null && received < total) {
        throw Exception('下载不完整 ($received/$total 字节)');
      }
      if (received < 1024) {
        throw Exception('音频文件异常 ($received 字节)');
      }

      final destination = File(path);
      if (await destination.exists()) {
        await destination.delete();
      }
      await tmp.rename(path);
      await File(_readyPath(dir, _key(track))).create();
      await saveTrackMetadata(track);
      _downloadedMemo[_key(track)] = true;

      _emit(DownloadProgress(track.id, received, total, true, null));
      await DatabaseService.saveDownloadedTrack(track);
      return path;
    } catch (e) {
      try {
        await sink?.close();
      } catch (_) {}
      // Deliberately keep the .part file: the next attempt resumes it via
      // Range instead of re-downloading from byte 0. Corrupt or unwanted
      // partial data is handled there (a 200 answer restarts from scratch).
      _emit(DownloadProgress(track.id, 0, null, false, '$e'));
      rethrow;
    }
  }

  static void _emit(DownloadProgress p) {
    if (!_progressController.isClosed) _progressController.add(p);
  }
}
