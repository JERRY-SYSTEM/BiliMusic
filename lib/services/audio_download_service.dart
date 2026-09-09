import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../models/audio_quality.dart';
import 'bili_auth_service.dart';
import 'bili_http.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';
import 'app_database.dart';

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

  @visibleForTesting
  static void configureForTesting(String directory) {
    _dirPath = directory;
    _downloadedMemo.clear();
  }

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
    final path = '${docs.path}/bilimusic_audio';
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

  static String _audioPath(String dir, String key, [int? quality]) => quality == null || quality == 0 ? '$dir/audio_$key.m4a' : '$dir/audio_${key}_$quality.m4a';
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
  static Future<bool> isDownloaded(Track track, {int? quality}) => isDownloadedById(_key(track), quality: quality);

  /// True when any quality variant for [track] is cached. Playlist/search
  /// entries do not retain the quality selected in the download dialog, so
  /// checking only the default (quality 0) path incorrectly leaves the
  /// download button visible after a successful high-quality download.
  static Future<bool> isAnyQualityDownloaded(Track track) async {
    for (final row in await AppDatabase.downloads(trackId: _key(track))) {
      if (await isDownloadedById(_key(track), quality: row['quality'] as int)) return true;
    }
    return false;
  }

  /// String-id variant of [isDownloaded] for callers that only hold an id.
  static Future<bool> isDownloadedById(String id, {int? quality}) async {
    final cacheKey = '${id}_${quality ?? 0}';
    final memo = _downloadedMemo[cacheKey];
    if (memo != null) return memo;
    final result = await _statDownloaded(id, quality);
    _downloadedMemo[cacheKey] = result;
    if (_downloadedMemo.length > _memoCap) {
      _downloadedMemo.remove(_downloadedMemo.keys.first);
    }
    return result;
  }

  static Future<bool> _statDownloaded(String id, int? quality) async {
    final rows = await AppDatabase.downloads(trackId: id);
    for (final row in rows.where((row) => row['quality'] == (quality ?? 0))) {
      final audio = File(row['path'] as String);
      if (await audio.exists() && await audio.length() == row['bytes'] && (row['bytes'] as int) > 0) return true;
      await AppDatabase.forgetDownload(id, quality ?? 0);
    }
    return false;
  }

  /// Reconcile registered downloads with disk without rediscovering old files.
  /// Unregistered files remain visible in the cache inventory's Other bucket.
  static Future<void> reconcileDownloads() async {
    for (final row in await AppDatabase.downloads()) {
      final id = row['track_id'] as String;
      final quality = row['quality'] as int;
      final file = File(row['path'] as String);
      if (!await file.exists() || await file.length() != row['bytes']) {
        await AppDatabase.forgetDownload(id, quality);
        _downloadedMemo.remove('${id}_$quality');
      }
    }
  }

  /// Remove one quality, updating the index only after its file is removed.
  static Future<bool> delete(Track track, {int? quality}) async {
    final id = _key(track);
    final dir = await _dir();
    var deleted = false;
    for (final row in await AppDatabase.downloads(trackId: id)) {
      if (row['quality'] != (quality ?? 0)) continue;
      final file = File(row['path'] as String);
      if (await file.exists()) { await file.delete(); deleted = true; }
    }
    final part = File('${_audioPath(dir, id, quality)}.part');
    if (await part.exists()) { await part.delete(); deleted = true; }
    await AppDatabase.forgetDownload(id, quality ?? 0);
    _downloadedMemo.remove('${id}_${quality ?? 0}');
    return deleted;
  }

  static Future<void> deleteAllForTrack(Track track) async {
    final id = _key(track);
    for (final row in await AppDatabase.downloads(trackId: id)) {
      final file = File(row['path'] as String);
      if (await file.exists()) await file.delete();
    }
    // Match the whole track id, not a prefix that can also match another part.
    final pattern = RegExp('^audio_${RegExp.escape(id)}(?:_[0-9]+)?\\.m4a(?:\\.part)?\$');
    for (final entity in await Directory(await _dir()).list().toList()) {
      if (entity is File && pattern.hasMatch(entity.uri.pathSegments.last)) await entity.delete();
    }
    await AppDatabase.forgetDownload(id, null);
    _downloadedMemo.removeWhere((key, _) => key.startsWith('${id}_'));
  }

  /// Ensures [track]'s audio is fully downloaded and returns the local path.
  ///
  /// Idempotent and concurrency-safe: a second call for the same track while a
  /// download is in flight awaits the same future instead of downloading twice.
  static Future<String> ensureDownloaded(Track track, {AudioQualityOption? quality}) async {
    if (quality == null && track.qualityId != null) {
      final options = await BilibiliSdk.fetchAudioQualities(track.bvid, track.cid,
          cookies: BiliAuthController.instance.session?.cookie,
          preferredQuality: track.qualityId);
      for (final option in options) {
        if (option.id == track.qualityId) {
          quality = option;
          break;
        }
      }
    }
    final dir = await _dir();
    final id = _key(track);
    final path = _audioPath(dir, id, quality?.id);
    // Validate again before playback: a file may have disappeared since a
    // list row last asked for its cached download status.
    if (await _statDownloaded(id, quality?.id)) {
      return path;
    }

    final flightKey = '${id}_${quality?.id ?? 0}';
    final existing = _inFlight[flightKey];
    if (existing != null) return existing;

    final future = _download(track, path, quality);
    _inFlight[flightKey] = future;
    try {
      return await future;
    } finally {
      _inFlight.remove(flightKey);
    }
  }

  static Future<String> _download(Track track, String path, AudioQualityOption? quality) async {
    var url = quality?.url ?? track.audioUrl;
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
      // Only finalize a resumed 416 when Content-Range proves the local size
      // matches the complete resource. A stale/oversized partial is not audio.
      if (res.statusCode == HttpStatus.requestedRangeNotSatisfiable &&
          existing > 0) {
        final range = res.headers.value(HttpHeaders.contentRangeHeader);
        final total = int.tryParse(range?.split('/').last ?? '');
        await res.drain<void>();
        if (total != existing || existing < 1024) {
          await tmp.delete();
          throw Exception('下载断点已失效，请重试');
        }
        final destination = File(path);
        if (await destination.exists()) {
          await destination.delete();
        }
        await tmp.rename(path);
        await DatabaseService.registerDownload(track, quality?.id ?? 0, path, await File(path).length());
        _downloadedMemo['${_key(track)}_${quality?.id ?? 0}'] = true;
        _emit(DownloadProgress(track.id, existing, existing, true, null));
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
          // IOSink.add does not apply backpressure. Without awaiting writes,
          // a fast CDN can queue a whole audio file in memory on slow storage.
          await sink.flush();
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
      await DatabaseService.registerDownload(track, quality?.id ?? 0, path, await File(path).length());
      _downloadedMemo['${_key(track)}_${quality?.id ?? 0}'] = true;

      _emit(DownloadProgress(track.id, received, total, true, null));
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
