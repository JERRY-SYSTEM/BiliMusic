import 'dart:async';

import '../models/lyric_line.dart';
import '../models/track.dart';
import 'app_database.dart';
import 'database_service.dart';
import 'lyrics_engine.dart';

/// Resolves a Bilibili track to a music-catalog song exactly once at a time.
/// A failed automatic cover match is persisted so reopening the same song
/// does not repeat the provider requests.
class TrackEnrichmentService {
  TrackEnrichmentService._();

  static final Map<String, Future<Track?>> _inFlight = {};
  static final StreamController<Track> _updates = StreamController.broadcast();
  static Stream<Track> get updates => _updates.stream;

  static Future<Track?> enrich(Track track) {
    return _inFlight.putIfAbsent(track.id, () async {
      final needsCover = track.coverUrl.isEmpty;
      try {
        if (needsCover && await AppDatabase.hasCoverMatchFailed(track.id)) {
          return track;
        }
        if (track.musicSource.isNotEmpty &&
            track.musicId.isNotEmpty &&
            track.coverUrl.isNotEmpty &&
            await DatabaseService.getCachedLyrics(track.id) != null) {
          return track;
        }
        LyricsResult? result;
        if (track.musicSource.isNotEmpty && track.musicId.isNotEmpty) {
          final provider = LyricProvider.values.firstWhere(
            (item) => item.apiName == track.musicSource,
          );
          LyricSearchCandidate? matched;
          final candidates = await LyricsEngine.searchCandidates(
            '${track.title} ${track.uploader}',
            provider: provider,
          );
          for (final candidate in candidates) {
            if (candidate.id == track.musicId) {
              matched = candidate;
              break;
            }
          }
          result = matched == null
              ? await LyricsEngine.fetchReferenceLyrics(LyricsReference(
                  provider: provider,
                  id: track.musicId,
                  title: track.title,
                  artist: track.uploader,
                  pictureUrl: track.coverUrl.isEmpty ? null : track.coverUrl,
                ))
              : await LyricsEngine.fetchCandidateLyrics(matched);
        } else {
          result = await LyricsEngine.autoFetchLyrics(track.rawTitle);
        }
        if (result == null ||
            result.reference == null ||
            result.lines.isEmpty) {
          if (needsCover) {
            await AppDatabase.markCoverMatchFailed(track.id);
          }
          return null;
        }
        final updated = await DatabaseService.completeTrackEnrichment(track, result);
        if (updated.coverUrl.isEmpty) {
          await AppDatabase.markCoverMatchFailed(track.id);
        }
        _updates.add(updated);
        return updated;
      } catch (_) {
        if (needsCover) {
          await AppDatabase.markCoverMatchFailed(track.id);
        }
        return null;
      } finally {
        _inFlight.remove(track.id);
      }
    });
  }

  static void enrichInBackground(Track track) {
    unawaited(enrich(track));
  }
}
