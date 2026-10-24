import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../widgets/cached_cover_image.dart';
import 'app_database.dart';

/// Only complete audio, artwork and lyrics belong to a song bucket.
class CacheBucket {
  const CacheBucket({required this.track, required this.files, this.lyricsBytes = 0, this.coverFiles = const [], this.extraBytes = 0, this.lyricTrackIds = const []});
  final Track? track;
  final List<File> files;
  final int lyricsBytes;
  final List<File> coverFiles;
  final int extraBytes;
  final List<String> lyricTrackIds;
  bool get isOther => track == null;
  int get bytes => files.fold(0, (sum, file) => sum + _length(file)) + lyricsBytes + extraBytes + coverFiles.fold(0, (sum, file) => sum + _length(file));
  static int _length(File file) { try { return file.lengthSync(); } catch (_) { return 0; } }
}

class CacheInventory {
  CacheInventory._();

  static Future<List<CacheBucket>> load(List<Track> tracks) async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final buckets = <String, CacheBucket>{
      for (final track in tracks) track.id: CacheBucket(track: track, files: <File>[]),
    };
    final coverOwnerByPath = <String, String>{};
    final db = await AppDatabase.instance;
    for (final row in await db.query('tracks')) {
      final track = Track.fromMap(AppDatabase.decode(row['payload']));
      buckets.putIfAbsent(track.id, () => CacheBucket(track: track, files: <File>[]));
    }
    // Protect thumbnails created before playlist artwork had its own directory.
    final playlistKeys = <String>{};
    final playlistPaths = <String>{};
    for (final row in await db.query('playlists')) {
      final url = AppDatabase.decode(row['payload'])['coverUrl'] as String?;
      if (url == null || url.isEmpty) continue;
      if (CachedCoverImage.isLocalPath(url)) {
        playlistPaths.add(File(CachedCoverImage.localPathOf(url)).absolute.path);
        continue;
      }
      for (var size = 1; size <= 1080; size++) {
        playlistKeys.add(md5.convert(utf8.encode(CachedCoverImage.sizedUrl(url, size, size))).toString());
      }
    }
    for (final row in await AppDatabase.coverCaches()) {
      try {
        final track = Track.fromMap(AppDatabase.decode(row['track_payload']));
        buckets.putIfAbsent(
          track.id,
          () => CacheBucket(track: track, files: <File>[]),
        );
        coverOwnerByPath[row['path'] as String] = track.id;
      } catch (_) {
        // A malformed ownership row must not make the cache page unusable.
      }
    }
    final otherFiles = <File>[];
    var otherBytes = 0;
    final otherLyrics = <String>[];
    final lyricBytesByTrack = <String, int>{};
    final lyricRows = await (await AppDatabase.instance)
        .query('lyrics', columns: ['track_id', 'lines_json']);
    for (final row in lyricRows) {
      final trackId = row['track_id'] as String;
      final payload = row['lines_json'] as String?;
      if (payload == null) continue;
      final bytes = utf8.encode(payload).length;
      if (buckets.containsKey(trackId)) {
        lyricBytesByTrack[trackId] = bytes;
      } else {
        otherBytes += bytes;
        otherLyrics.add(trackId);
      }
    }
    final coverByTrack = <String, List<File>>{};
    final localCoverOwners = {
      for (final bucket in buckets.values)
        if (CachedCoverImage.isLocalPath(bucket.track!.coverUrl))
          File(CachedCoverImage.localPathOf(bucket.track!.coverUrl)).absolute.path: bucket.track!.id,
    };
    final customCovers = Directory('${docs.path}/bilimusic_covers');
    if (await customCovers.exists()) {
      await for (final entity in customCovers.list(followLinks: false)) {
        if (entity is! File || playlistPaths.contains(entity.absolute.path)) continue;
        final owner = localCoverOwners[entity.absolute.path];
        if (owner == null) {
          otherFiles.add(entity);
        } else {
          (coverByTrack[owner] ??= []).add(entity);
        }
      }
    }
    final audioDir = Directory('${docs.path}/bilimusic_audio');
    final audioOwners = {for (final row in await AppDatabase.downloads()) row['path'] as String: row['track_id'] as String};
    if (await audioDir.exists()) {
      for (final entity in await audioDir.list().toList()) {
        if (entity is! File) continue;
        final bucket = entity.path.endsWith('.m4a') ? buckets[audioOwners[entity.path]] : null;
        (bucket?.files ?? otherFiles).add(entity);
      }
    }
    final coversDir = Directory('${support.path}/bilimusic_covers');
    Map<String, Track>? legacyOwners;
    Map<String, Track> buildLegacyOwners() {
      final owners = <String, Track>{};
      for (final bucket in buckets.values) {
        final track = bucket.track!;
        if (track.coverUrl.isEmpty || CachedCoverImage.isLocalPath(track.coverUrl)) continue;
        final systemKey = md5.convert(utf8.encode(track.coverUrl)).toString();
        owners.putIfAbsent('system_$systemKey.jpg', () => track);
        for (var size = 1; size <= 1080; size++) {
          final key = md5.convert(utf8.encode(CachedCoverImage.sizedUrl(track.coverUrl, size, size))).toString();
          owners.putIfAbsent('img_$key.img', () => track);
        }
      }
      return owners;
    }
    if (await coversDir.exists()) {
      for (final entity in await coversDir.list().toList()) {
        if (entity is! File) continue;
        final name = entity.uri.pathSegments.last;
        if (playlistKeys.any((key) => name == 'img_$key.img')) continue;
        if (name.endsWith('.part')) {
          otherFiles.add(entity);
          continue;
        }
        final registeredId = coverOwnerByPath[entity.path];
        final owner = buckets[registeredId]?.track ??
            (legacyOwners ??= buildLegacyOwners())[name];
        if (owner == null) {
          otherFiles.add(entity);
        } else {
          (coverByTrack[owner.id] ??= []).add(entity);
        }
      }
    }
    final temporary = await getTemporaryDirectory();
    if (await temporary.exists()) {
      await for (final entity in temporary.list(recursive: true, followLinks: false)) {
        if (entity is File) otherFiles.add(entity);
      }
    }
    final result = <CacheBucket>[
      ...buckets.values.map((bucket) => CacheBucket(
            track: bucket.track,
            files: bucket.files,
            lyricsBytes: lyricBytesByTrack[bucket.track!.id] ?? 0,
            coverFiles: coverByTrack[bucket.track!.id] ?? const [],
          )),
      if (otherFiles.isNotEmpty || otherBytes > 0)
        CacheBucket(track: null, files: otherFiles, extraBytes: otherBytes, lyricTrackIds: otherLyrics),
    ];
    result.removeWhere((bucket) => bucket.bytes == 0);
    final sizes = {for (final bucket in result) bucket: bucket.bytes};
    result.sort((a, b) => sizes[b]!.compareTo(sizes[a]!));
    return result;
  }
}
