import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import 'database_service.dart';
import 'app_database.dart';
import '../widgets/cached_cover_image.dart';

/// A user-facing cache bucket. A bucket contains every cache artifact that can
/// be confidently attributed to one song; everything else is [other].
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
    final otherFiles = <File>[];
    var otherBytes = 0;
    final otherLyrics = <String>[];
    final coverByTrack = <String, List<File>>{};
    final audioDir = Directory('${docs.path}/bilimusic_audio');
    final audioOwners = {for (final row in await AppDatabase.downloads()) row['path'] as String: row['track_id'] as String};
    if (await audioDir.exists()) {
      for (final entity in await audioDir.list().toList()) {
        if (entity is! File) continue;
        final bucket = buckets[audioOwners[entity.path]];
        (bucket?.files ?? otherFiles).add(entity);
      }
    }
    final lyricsSizes = await DatabaseService.lyricsSizes();
    for (final entry in lyricsSizes.entries) {
      final bucket = buckets[entry.key];
      if (bucket == null) { otherBytes += entry.value; otherLyrics.add(entry.key); }
      else { buckets[entry.key] = CacheBucket(track: bucket.track, files: bucket.files, lyricsBytes: entry.value); }
    }
    final coversDir = Directory('${support.path}/bilimusic_covers');
    if (await coversDir.exists()) {
      // Hash each track/size once, not once per file in a growing cache.
      final owners = <String, Track>{};
      for (final track in tracks) {
        if (track.coverUrl.isEmpty || CachedCoverImage.isLocalPath(track.coverUrl)) continue;
        // Cover filenames are dimension-specific. Without a persisted
        // ownership map, historical files remain safely in “其它”.
        for (final size in const [40, 44, 48, 54, 64, 72, 80, 120, 140, 160, 240, 320]) {
          final key = md5.convert(utf8.encode(CachedCoverImage.sizedUrl(track.coverUrl, size, size))).toString();
          owners.putIfAbsent('img_$key.img', () => track);
        }
        // Yield to UI events while indexing a large library.
        await Future<void>.delayed(Duration.zero);
      }
      await for (final entity in coversDir.list()) {
        if (entity is! File) continue;
        final owner = owners[entity.uri.pathSegments.last];
        if (owner == null) {
          otherFiles.add(entity);
        } else {
          (coverByTrack[owner.id] ??= []).add(entity);
        }
      }
    }
    final result = <CacheBucket>[
      ...buckets.values.map((bucket) => CacheBucket(
            track: bucket.track,
            files: bucket.files,
            lyricsBytes: bucket.lyricsBytes,
            coverFiles: coverByTrack[bucket.track!.id] ?? const [],
          )),
      if (otherFiles.isNotEmpty || otherBytes > 0)
        CacheBucket(track: null, files: otherFiles, extraBytes: otherBytes, lyricTrackIds: otherLyrics),
    ];
    result.sort((a, b) => a.isOther == b.isOther ? 0 : (a.isOther ? -1 : 1));
    return result;
  }
}
