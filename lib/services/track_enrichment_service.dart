import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/lyric_line.dart';
import '../models/track.dart';
import 'database_service.dart';
import 'lyrics_engine.dart';

/// Resolves a Bilibili track to a music-catalog song exactly once at a time.
/// Request failures are deliberately not memoized so a later display can
/// retry. A successful search with no usable match is persisted separately.
class TrackEnrichmentService {
  TrackEnrichmentService._();

  static final Map<String, Future<Track?>> _inFlight = {};
  static final Map<String, int> _revisions = {};
  static final StreamController<Track> _updates = StreamController.broadcast();
  static Stream<Track> get updates => _updates.stream;

  static Future<Track?> enrich(Track track) =>
      _enrich(track, LyricsEngine.autoFetchLyrics);

  @visibleForTesting
  static Future<Track?> enrichForTesting(
    Track track,
    Future<LyricsResult> Function(String rawTitle) autoFetchLyrics,
  ) => _enrich(track, autoFetchLyrics);

  static Future<Track?> _enrich(
    Track track,
    Future<LyricsResult> Function(String rawTitle) autoFetchLyrics,
  ) {
    return _inFlight.putIfAbsent(track.id, () async {
      final revision = _revisions[track.id] ?? 0;
      try {
        if (await DatabaseService.hasAutoCoverMatchMiss(track.id)) {
          return null;
        }
        if (track.musicSource.isNotEmpty &&
            track.musicId.isNotEmpty &&
            track.coverUrl.isNotEmpty &&
            await DatabaseService.getCachedLyrics(track.id) != null) {
          return track;
        }
        final isAutomaticCatalogMatch =
            track.musicSource.isEmpty || track.musicId.isEmpty;
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
          result = await autoFetchLyrics(track.rawTitle);
        }
        if (result == null ||
            result.reference == null ||
            result.lines.isEmpty) {
          if ((_revisions[track.id] ?? 0) != revision) return null;
          // For an automatic catalog lookup, reaching this branch means the
          // provider answered normally but no usable match was found.
          // Exceptions take the catch path below and remain retryable.
          if (isAutomaticCatalogMatch) {
            await DatabaseService.markAutoCoverMatchMiss(track.id);
          }
          return null;
        }
        if ((_revisions[track.id] ?? 0) != revision) return null;
        final updated =
            await DatabaseService.completeTrackEnrichment(track, result);
        if (updated.coverUrl.isEmpty) {
          await DatabaseService.markAutoCoverMatchMiss(track.id);
        }
        _updates.add(updated);
        return updated;
      } catch (_) {
        return null;
      } finally {
        _inFlight.remove(track.id);
      }
    });
  }

  /// Prevents an older automatic lookup from writing after the user has
  /// explicitly selected a different catalog entry.
  static void supersedePending(String trackId) {
    _revisions[trackId] = (_revisions[trackId] ?? 0) + 1;
  }

  static void enrichInBackground(Track track) {
    unawaited(enrich(track));
  }
}
