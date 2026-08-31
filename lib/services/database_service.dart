import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/track.dart';
import '../models/playlist.dart';
import '../models/lyric_line.dart';
import 'audio_download_service.dart';

/// Parse helpers run inside a background isolate (via [compute]): a large
/// library means several files of jsonDecode + object construction, and doing
/// that on the UI isolate blocked the first frame after startup. They are
/// top-level because isolate entry points must be top-level or static, and
/// they only touch pure model constructors — never the service's static state.
List<Track> _parseTrackList(String json) {
  final list =
      DatabaseService._readPayload(jsonDecode(json)) as List<dynamic>? ?? [];
  return list
      .map((item) => Track.fromMap(Map<String, dynamic>.from(item)))
      .toList();
}

List<Playlist> _parsePlaylistList(String json) {
  final list =
      DatabaseService._readPayload(jsonDecode(json)) as List<dynamic>? ?? [];
  return list.map((item) {
    final map = Map<String, dynamic>.from(item);
    final tracks = (map['tracks'] as List<dynamic>? ?? [])
        .map((t) => Track.fromMap(Map<String, dynamic>.from(t)))
        .toList();
    return Playlist.fromMap(map, tracks: tracks);
  }).toList();
}

Map<String, LyricsResult> _parseLyricsMap(String json) {
  final map = DatabaseService._readPayload(jsonDecode(json))
      as Map<String, dynamic>? ?? {};
  final result = <String, LyricsResult>{};
  map.forEach((key, value) {
    try {
      result[key] =
          LyricsResult.fromMap(Map<String, dynamic>.from(value as Map));
    } catch (e) {
      debugPrint('Lyrics cache entry $key skipped: $e');
    }
  });
  return result;
}

class DatabaseService {
  static final List<Track> _recentlyPlayed = [];
  static final List<Track> _downloadedTracks = [];
  static final Map<String, LyricsResult> _lyricsCache = {};
  static final List<String> _searchHistory = [];
  static final StreamController<void> _libraryUpdateController = StreamController<void>.broadcast();
  static final StreamController<void> _historyUpdateController = StreamController<void>.broadcast();
  static Future<void>? _loadFuture;

  /// Emitted when the library changes: downloads, playlists or favourites.
  /// Screens subscribe to this instead of relying on whichever call site
  /// happened to make the change to also remember to refresh them.
  static Stream<void> get libraryUpdateStream => _libraryUpdateController.stream;

  /// Emitted when the recently-played list changes — including when the audio
  /// handler auto-advances, which no UI action would otherwise notice.
  static Stream<void> get historyUpdateStream => _historyUpdateController.stream;

  /// Cap on the in-memory + on-disk lyrics cache.
  static const int _maxLyricsCacheEntries = 200;

  static final List<Playlist> _playlists = [
    Playlist(id: Playlist.favoritesId, name: '收藏', tracks: [])
  ];

  static int _playlistSeq = 0;

  /// Cached documents directory. The path is fixed for the lifetime of the
  /// app, yet every persist used to re-fetch it across the platform channel.
  static String? _docsPath;
  static Future<String> _docs() async {
    final cached = _docsPath;
    if (cached != null) return cached;
    final docs = await getApplicationDocumentsDirectory();
    return _docsPath = docs.path;
  }

  static Future<void> _ensureLoaded() => _loadFuture ??= _load();

  static Future<void> _load() async {
    try {
      final dir = await _docs();

      // Each file is parsed into a local list first, then swapped into the
      // store: one corrupt file must not wipe the whole in-memory library
      // (a truncated write is easy with whole-file rewrites).
      await _loadTracks('$dir/bilibeat_downloaded.json', _downloadedTracks);
      await _discoverAudioFiles(dir);
      await _loadTracks('$dir/bilibeat_recently_played.json', _recentlyPlayed);
      await _loadPlaylists('$dir/bilibeat_playlists.json');
      await _loadSearchHistory('$dir/bilibeat_search_history.json');
      await _loadLyricsCache('$dir/bilibeat_lyrics.json');
    } catch (e) {
      debugPrint('DatabaseService _ensureLoaded error: $e');
    }
  }

  static Future<void> _loadTracks(String path, List<Track> store) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      // Parse (jsonDecode + Track construction) in a background isolate so a
      // large library does not stall the first frame after startup.
      final tracks = await compute(_parseTrackList, await file.readAsString());
      store
        ..clear()
        ..addAll(tracks);
    } catch (e) {
      debugPrint('DatabaseService load $path skipped: $e');
    }
  }

  static Future<void> _discoverAudioFiles(String dir) async {
    try {
      final audioDir = Directory('$dir/bilibeat_audio');
      if (!await audioDir.exists()) return;
      final entities = await audioDir.list().toList();
      for (final entity in entities) {
        if (entity is File && entity.path.endsWith('.ready')) {
          final readyPath = entity.path;
          final audioPath = readyPath.replaceFirst('.ready', '.m4a');
          final metaPath = readyPath.replaceFirst('.ready', '.json');
          final audioFile = File(audioPath);
          final metaFile = File(metaPath);

          if (await audioFile.exists() && (await audioFile.length()) > 0 && await metaFile.exists()) {
            try {
              final metaContent = await metaFile.readAsString();
              final trackMap = Map<String, dynamic>.from(jsonDecode(metaContent));
              final track = Track.fromMap(trackMap);
              if (!_downloadedTracks.any((t) => t.id == track.id)) {
                _downloadedTracks.add(track);
              }
            } catch (e) {
              debugPrint('Auto-discover track error: $e');
            }
          }
        }
      }
    } catch (e) {
      debugPrint('DatabaseService audio discovery skipped: $e');
    }
  }

  static Future<void> _loadPlaylists(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final playlists =
          await compute(_parsePlaylistList, await file.readAsString());
      if (!playlists.any((p) => p.id == Playlist.favoritesId)) {
        playlists.insert(0, Playlist(id: Playlist.favoritesId, name: '收藏', tracks: []));
      }
      _playlists
        ..clear()
        ..addAll(playlists);
    } catch (e) {
      debugPrint('DatabaseService load $path skipped: $e');
    }
  }

  static Future<void> _loadSearchHistory(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final list = _readPayload(jsonDecode(await file.readAsString()))
          as List<dynamic>? ?? [];
      _searchHistory
        ..clear()
        ..addAll(list.map((e) => e.toString()));
    } catch (e) {
      debugPrint('DatabaseService load $path skipped: $e');
    }
  }

  static Future<void> _loadLyricsCache(String path) async {
    try {
      final file = File(path);
      if (!await file.exists()) return;
      final parsed = await compute(_parseLyricsMap, await file.readAsString());
      _lyricsCache
        ..clear()
        ..addAll(parsed);
    } catch (e) {
      debugPrint('DatabaseService load $path skipped: $e');
    }
  }

  /// Whole-file rewrites are truncated-then-written by default; a crash in the
  /// middle corrupts the file. Writing to a temp file and renaming keeps the
  /// previous snapshot intact instead.
  static Future<void> _writeJsonAtomically(String path, Object data) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(data));
    await tmp.rename(path);
  }

  /// Envelope version for every file this service writes. Bump when a payload
  /// shape changes incompatibly and teach the matching loader to migrate the
  /// old version. Files written before versioning existed hold bare payloads
  /// (no envelope); every loader accepts both, so the first write after an
  /// upgrade migrates each file in place.
  static const int schemaVersion = 1;

  static Map<String, dynamic> _envelope(Object payload) =>
      {'schema_version': schemaVersion, 'data': payload};

  /// Unwraps a persisted payload, accepting both the versioned envelope and
  /// the bare legacy shape. Returns null for envelopes written by a NEWER
  /// schema than this build understands: guessing at unknown future data and
  /// then re-persisting the guess would destroy it.
  static dynamic _readPayload(dynamic decoded) {
    if (decoded is Map && decoded.containsKey('schema_version')) {
      final version = decoded['schema_version'];
      if (version is int && version > schemaVersion) {
        debugPrint('DatabaseService: file has schema_version $version > '
            '$schemaVersion; written by a newer build, skipping');
        return null;
      }
      return decoded['data'];
    }
    return decoded;
  }

  static Future<void> _persistDownloaded() async {
    try {
      final dir = await _docs();
      await _writeJsonAtomically('$dir/bilibeat_downloaded.json',
          _envelope(_downloadedTracks.map((t) => t.toMap()).toList()));
    } catch (e) {
      debugPrint('DatabaseService _persistDownloaded error: $e');
    }
  }

  static Future<void> _persistRecentlyPlayed() async {
    try {
      final dir = await _docs();
      await _writeJsonAtomically('$dir/bilibeat_recently_played.json',
          _envelope(_recentlyPlayed.map((t) => t.toMap()).toList()));
    } catch (e) {
      debugPrint('DatabaseService _persistRecentlyPlayed error: $e');
    }
  }

  static Future<void> _persistPlaylists() async {
    try {
      final dir = await _docs();
      final list = _playlists.map((p) {
        final map = p.toMap();
        map['tracks'] = p.tracks.map((t) => t.toMap()).toList();
        return map;
      }).toList();
      await _writeJsonAtomically('$dir/bilibeat_playlists.json', _envelope(list));
    } catch (e) {
      debugPrint('DatabaseService _persistPlaylists error: $e');
    }
    if (!_libraryUpdateController.isClosed) _libraryUpdateController.add(null);
  }

  static Future<void> _persistSearchHistory() async {
    try {
      final dir = await _docs();
      await _writeJsonAtomically(
          '$dir/bilibeat_search_history.json', _envelope(_searchHistory));
    } catch (e) {
      debugPrint('DatabaseService _persistSearchHistory error: $e');
    }
  }

  static Future<List<String>> getSearchHistory() async {
    await _ensureLoaded();
    return List<String>.from(_searchHistory);
  }

  static Future<List<String>> addSearchHistory(String query) async {
    await _ensureLoaded();
    final q = query.trim();
    if (q.isEmpty) return List<String>.from(_searchHistory);
    _searchHistory.remove(q);
    _searchHistory.insert(0, q);
    if (_searchHistory.length > 12) _searchHistory.removeLast();
    await _persistSearchHistory();
    return List<String>.from(_searchHistory);
  }

  static Future<void> clearSearchHistory() async {
    await _ensureLoaded();
    _searchHistory.clear();
    await _persistSearchHistory();
  }

  static Future<void> updateTrackMetadata(Track updated) async {
    await _ensureLoaded();
    final dlIdx = _downloadedTracks.indexWhere((t) => t.id == updated.id);
    if (dlIdx != -1) {
      _downloadedTracks[dlIdx] = updated;
      await _persistDownloaded();
    }

    // Deliberate edit: this one does overwrite the on-disk copy.
    await AudioDownloadService.saveTrackMetadata(updated, force: true);

    for (final pl in _playlists) {
      final idx = pl.tracks.indexWhere((t) => t.id == updated.id);
      if (idx != -1) {
        pl.tracks[idx] = updated;
      }
    }
    await _persistPlaylists();

    final recIdx = _recentlyPlayed.indexWhere((t) => t.id == updated.id);
    if (recIdx != -1) {
      _recentlyPlayed[recIdx] = updated;
      await _persistRecentlyPlayed();
    }

    // _persistPlaylists above already emitted the library update.
    if (!_historyUpdateController.isClosed) _historyUpdateController.add(null);
  }

  static Future<List<Playlist>> getPlaylists() async {
    await _ensureLoaded();
    return List<Playlist>.from(_playlists);
  }

  static Future<Playlist> getFavoritesPlaylist() async {
    await _ensureLoaded();
    return _playlists.firstWhere(
      (p) => p.id == Playlist.favoritesId,
      orElse: () => Playlist(id: Playlist.favoritesId, name: '收藏', tracks: []),
    );
  }

  static Future<Playlist> createPlaylist(String name) async {
    await _ensureLoaded();
    final newPlaylist = Playlist(
      id: 'pl_${DateTime.now().millisecondsSinceEpoch}_${_playlistSeq++}',
      name: name.trim().isEmpty ? '新建歌单' : name.trim(),
      tracks: [],
    );
    _playlists.add(newPlaylist);
    await _persistPlaylists();
    return newPlaylist;
  }

  static Future<Playlist> createOnlinePlaylist({required String remoteId, required String name, String? coverUrl, required List<Track> tracks}) async {
    await _ensureLoaded();
    final playlist = Playlist(id: 'online_$remoteId', name: name, coverUrl: coverUrl, remoteId: remoteId, isOnline: true, lastSyncedAt: DateTime.now(), tracks: tracks);
    _playlists.removeWhere((p) => p.remoteId == remoteId);
    _playlists.add(playlist);
    await _persistPlaylists();
    return playlist;
  }

  /// Renames a playlist.
  static Future<void> renamePlaylist(String playlistId, String newName) async {
    await _ensureLoaded();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final old = _playlists[idx];
    _playlists[idx] = Playlist(
      id: old.id,
      name: newName.trim().isEmpty ? old.name : newName.trim(),
      coverUrl: old.coverUrl,
      remoteId: old.remoteId,
      isOnline: old.isOnline,
      lastSyncedAt: old.lastSyncedAt,
      tracks: old.tracks,
    );
    await _persistPlaylists();
  }

  /// Sets (or clears, with null) a playlist's cover image.
  static Future<void> setPlaylistCover(String playlistId, String? path) async {
    await _ensureLoaded();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final old = _playlists[idx];
    _playlists[idx] = Playlist(
      id: old.id,
      name: old.name,
      coverUrl: path,
      remoteId: old.remoteId,
      isOnline: old.isOnline,
      lastSyncedAt: old.lastSyncedAt,
      tracks: old.tracks,
    );
    await _persistPlaylists();
  }

  /// Moves a track within a playlist. Both indices are final positions —
  /// `onReorderItem` already accounts for the removal, unlike the deprecated
  /// `onReorder`, whose newIndex needed adjusting by hand.
  static Future<void> reorderPlaylist(
      String playlistId, int oldIndex, int newIndex) async {
    await _ensureLoaded();
    final pl = _playlists.firstWhere((p) => p.id == playlistId,
        orElse: () => Playlist(id: '', name: '', tracks: []));
    if (pl.id.isEmpty) return;
    _moveWithin(pl.tracks, oldIndex, newIndex);
    await _persistPlaylists();
  }

  /// The same, for the 本地 library, which is a list rather than a playlist.
  static Future<void> reorderDownloaded(int oldIndex, int newIndex) async {
    await _ensureLoaded();
    _moveWithin(_downloadedTracks, oldIndex, newIndex);
    await _persistDownloaded();
    if (!_libraryUpdateController.isClosed) _libraryUpdateController.add(null);
  }

  static void _moveWithin(List<Track> list, int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= list.length) return;
    final track = list.removeAt(oldIndex);
    list.insert(newIndex.clamp(0, list.length), track);
  }

  static Future<void> deletePlaylist(String playlistId) async {
    await _ensureLoaded();
    if (playlistId == Playlist.favoritesId) return;
    _playlists.removeWhere((p) => p.id == playlistId);
    await _persistPlaylists();
  }

  static Future<void> addTrackToPlaylist(String playlistId, Track track) async {
    await _ensureLoaded();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final playlist = _playlists[idx];
    if (!playlist.tracks.any((t) => t.id == track.id)) {
      playlist.tracks.insert(0, track);
      await _persistPlaylists();
    }
  }

  static Future<void> removeTrackFromPlaylist(String playlistId, String trackId) async {
    await _ensureLoaded();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1) return;
    final playlist = _playlists[idx];
    playlist.tracks.removeWhere((t) => t.id == trackId);
    await _persistPlaylists();
  }

  /// Batch variant of [addTrackToPlaylist]: one persist for the whole batch
  /// instead of a full-file rewrite per track. Order matches calling the
  /// single-track version repeatedly (each insert goes to the front, so the
  /// batch's last item ends up first).
  static Future<void> addTracksToPlaylist(
      String playlistId, List<Track> tracks) async {
    await _ensureLoaded();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1 || tracks.isEmpty) return;
    final playlist = _playlists[idx];
    final existingIds = playlist.tracks.map((t) => t.id).toSet();
    final toAdd = <Track>[];
    for (final track in tracks) {
      if (!existingIds.contains(track.id)) {
        existingIds.add(track.id);
        toAdd.add(track);
      }
    }
    if (toAdd.isEmpty) return;
    playlist.tracks.insertAll(0, toAdd.reversed.toList());
    await _persistPlaylists();
  }

  /// Batch variant of [removeTrackFromPlaylist] — one persist per operation.
  static Future<void> removeTracksFromPlaylist(
      String playlistId, List<String> trackIds) async {
    await _ensureLoaded();
    final idx = _playlists.indexWhere((p) => p.id == playlistId);
    if (idx == -1 || trackIds.isEmpty) return;
    final idSet = trackIds.toSet();
    final playlist = _playlists[idx];
    final before = playlist.tracks.length;
    playlist.tracks.removeWhere((t) => idSet.contains(t.id));
    if (playlist.tracks.length != before) await _persistPlaylists();
  }

  static Future<bool> isFavorite(String trackId) async {
    await _ensureLoaded();
    final favorites = await getFavoritesPlaylist();
    return favorites.tracks.any((t) => t.id == trackId);
  }

  static Future<bool> toggleFavorite(Track track) async {
    await _ensureLoaded();
    final favorites = await getFavoritesPlaylist();
    final exists = favorites.tracks.any((t) => t.id == track.id);

    if (exists) {
      favorites.tracks.removeWhere((t) => t.id == track.id);
      await _persistPlaylists();
      return false;
    } else {
      favorites.tracks.insert(0, track);
      await _persistPlaylists();
      return true;
    }
  }

  /// Records a play. De-duplication is by track **id** (`bvid_cid`) only:
  /// keying by `bvid` used to collapse the separate parts (P1/P2/…) of one
  /// video into a single entry, silently dropping tracks from the list.
  static Future<void> addRecentlyPlayed(Track track) async {
    await _ensureLoaded();
    final alreadyFirst =
        _recentlyPlayed.isNotEmpty && _recentlyPlayed.first.id == track.id;
    _recentlyPlayed.removeWhere((t) => t.id == track.id);
    _recentlyPlayed.insert(0, track);
    if (_recentlyPlayed.length > 50) _recentlyPlayed.removeLast();
    await _persistRecentlyPlayed();
    if (!alreadyFirst) _historyUpdateController.add(null);
  }

  static Future<List<Track>> getRecentlyPlayed() async {
    await _ensureLoaded();
    return List<Track>.from(_recentlyPlayed);
  }

  /// Registers [track] as available offline.
  ///
  /// If the library already knows this track, it is left exactly as it is.
  /// Playback calls this on every start with a possibly stale copy, and
  /// overwriting here reverted any title/artist/cover the user had edited —
  /// [updateTrackMetadata] is the only thing allowed to change that.
  static Future<void> saveDownloadedTrack(Track track) async {
    await _ensureLoaded();
    if (_downloadedTracks.any((t) => t.id == track.id)) return;
    _downloadedTracks.insert(0, track);
    await _persistDownloaded();
    if (!_libraryUpdateController.isClosed) _libraryUpdateController.add(null);
  }

  /// Deletes the local audio for [track] and forgets it from the library,
  /// playlists and the recently-played rail. (Leaving it in history meant a
  /// tap on the stale entry silently re-downloaded the song.)
  static Future<void> removeDownloadedTrack(Track track) async {
    await _ensureLoaded();
    await AudioDownloadService.delete(track);
    _downloadedTracks.removeWhere((t) => t.id == track.id);
    await _persistDownloaded();
    for (final pl in _playlists) {
      pl.tracks.removeWhere((t) => t.id == track.id);
    }
    await _persistPlaylists();
    final removedFromHistory =
        _recentlyPlayed.where((t) => t.id == track.id).isNotEmpty;
    _recentlyPlayed.removeWhere((t) => t.id == track.id);
    if (removedFromHistory) await _persistRecentlyPlayed();
    if (!_libraryUpdateController.isClosed) _libraryUpdateController.add(null);
    if (removedFromHistory && !_historyUpdateController.isClosed) {
      _historyUpdateController.add(null);
    }
  }

  static Future<List<Track>> getDownloadedTracks() async {
    await _ensureLoaded();
    return List<Track>.from(_downloadedTracks);
  }

  static Future<void> cacheLyrics(String trackId, LyricsResult lyrics) async {
    await _ensureLoaded();
    // Do not persist "not found" placeholders: they would stick forever and
    // stop the app from ever retrying a lookup that might succeed later.
    if (lyrics.source == 'none') {
      _lyricsCache.remove(trackId);
      return;
    }
    _lyricsCache[trackId] = lyrics;
    while (_lyricsCache.length > _maxLyricsCacheEntries) {
      _lyricsCache.remove(_lyricsCache.keys.first);
    }
    await _persistLyrics();
  }

  static Future<LyricsResult?> getCachedLyrics(String trackId) async {
    await _ensureLoaded();
    return _lyricsCache[trackId];
  }

  static Future<void> removeCachedLyrics(String trackId) async {
    await _ensureLoaded();
    if (_lyricsCache.remove(trackId) != null) await _persistLyrics();
  }

  static Future<void> _persistLyrics() async {
    try {
      final dir = await _docs();
      final map = _lyricsCache.map((k, v) => MapEntry(k, v.toMap()));
      await _writeJsonAtomically('$dir/bilibeat_lyrics.json', _envelope(map));
    } catch (e) {
      debugPrint('DatabaseService _persistLyrics error: $e');
    }
  }
}
