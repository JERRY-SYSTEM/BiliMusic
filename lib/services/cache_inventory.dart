import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../widgets/cached_cover_image.dart';
import 'audio_download_service.dart';

/// A user-facing cache bucket. A bucket contains every cache artifact that can
/// be confidently attributed to one song; everything else is [other].
class CacheBucket {
  const CacheBucket({required this.track, required this.files, this.lyricsBytes = 0, this.coverFiles = const [], this.extraBytes = 0});
  final Track? track;
  final List<File> files;
  final int lyricsBytes;
  final List<File> coverFiles;
  final int extraBytes;
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
    final coverByTrack = <String, List<File>>{};
    final audioDir = Directory('${docs.path}/bilibeat_audio');
    if (await audioDir.exists()) {
      for (final entity in await audioDir.list().toList()) {
        if (entity is! File) continue;
        Track? match;
        for (final track in tracks) {
          if (entity.path.contains('audio_${track.id}')) { match = track; break; }
        }
        (match == null ? otherFiles : buckets[match.id]!.files).add(entity);
      }
    }
    final lyricsFile = File('${docs.path}/bilibeat_lyrics.json');
    if (await lyricsFile.exists()) {
      try {
        final raw = jsonDecode(await lyricsFile.readAsString());
        final map = raw is Map && raw['data'] is Map ? raw['data'] as Map : raw as Map;
        for (final entry in map.entries) {
          final track = buckets[entry.key.toString()]?.track;
          final bytes = utf8.encode(jsonEncode({entry.key.toString(): entry.value})).length;
          if (track == null) { otherBytes += bytes; } else {
            buckets[track.id] = CacheBucket(track: track, files: buckets[track.id]!.files, lyricsBytes: buckets[track.id]!.lyricsBytes + bytes);
          }
        }
      } catch (_) { otherFiles.add(lyricsFile); }
    }
    final coversDir = Directory('${support.path}/bilibeat_covers');
    if (await coversDir.exists()) {
      for (final entity in await coversDir.list().toList()) {
        if (entity is! File) continue;
        Track? owner;
        for (final track in tracks) {
          if (track.coverUrl.isEmpty || CachedCoverImage.isLocalPath(track.coverUrl)) continue;
          // Cover filenames are dimension-specific. Without a persisted
          // ownership map, historical files remain safely in “其它”.
          for (final size in const [40, 44, 48, 54, 64, 72, 80, 120, 140, 160, 240, 320]) {
            final key = md5.convert(utf8.encode(CachedCoverImage.sizedUrl(track.coverUrl, size, size))).toString();
            if (entity.path.contains(key)) { owner = track; break; }
          }
          if (owner != null) break;
        }
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
        CacheBucket(track: null, files: otherFiles, extraBytes: otherBytes),
    ];
    result.sort((a, b) => a.isOther == b.isOther ? 0 : (a.isOther ? -1 : 1));
    return result;
  }
}
