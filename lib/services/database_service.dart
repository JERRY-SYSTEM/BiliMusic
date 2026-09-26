import 'dart:async';
import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import '../models/bili_session.dart';
import '../models/lyric_line.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'app_database.dart';
import 'audio_download_service.dart';

/// SQLite is authoritative. Detached reads and post-commit notifications keep
/// unsuccessful writes from leaking into the visible library.
class DatabaseService {
  static final _libraryUpdates = StreamController<void>.broadcast();
  static final _historyUpdates = StreamController<void>.broadcast();
  static Stream<void> get libraryUpdateStream => _libraryUpdates.stream;
  static Stream<void> get historyUpdateStream => _historyUpdates.stream;
  static int _playlistSeq = 0;
  static Future<T> _write<T>(Future<T> Function(Transaction) action, {bool library = false, bool history = false}) async {
    final result = await (await AppDatabase.instance).transaction((txn) async {
      final result = await action(txn);
      await AppDatabase.pruneTracks(txn);
      return result;
    });
    if (library) _libraryUpdates.add(null);
    if (history) _historyUpdates.add(null);
    return result;
  }
  static Future<List<Track>> _tracks(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery('SELECT t.payload FROM $table r JOIN tracks t ON t.id = r.track_id ORDER BY r.position');
    return rows.map((r) => Track.fromMap(AppDatabase.decode(r['payload']))).toList();
  }
  static Future<List<Playlist>> _playlists(DatabaseExecutor db) async {
    final rows = await db.query('playlists', orderBy: 'position');
    final result = <Playlist>[];
    for (final row in rows) {
      final members = await db.rawQuery('SELECT t.payload FROM playlist_tracks p JOIN tracks t ON t.id = p.track_id WHERE p.playlist_id = ? ORDER BY p.position', [row['id']]);
      result.add(Playlist.fromMap(AppDatabase.decode(row['payload']), tracks: members.map((r) => Track.fromMap(AppDatabase.decode(r['payload']))).toList()));
    }
    return result;
  }
  static Future<void> _savePlaylists(DatabaseExecutor db, List<Playlist> playlists) async {
    await db.delete('playlist_tracks');
    await db.delete('playlists');
    for (var i = 0; i < playlists.length; i++) {
      final p = playlists[i];
      await db.insert('playlists', {'id': p.id, 'position': i, 'payload': jsonEncode(p.toMap())});
      final seen = <String>{};
      for (var j = 0; j < p.tracks.length; j++) {
        final t = p.tracks[j];
        if (!seen.add(t.id)) continue;
        await AppDatabase.putTrack(db, t);
        await db.insert('playlist_tracks', {'playlist_id': p.id, 'track_id': t.id, 'position': j});
      }
    }
  }
  static Future<void> _editPlaylists(void Function(List<Playlist>) edit) => _write((txn) async {
    final all = await _playlists(txn);
    edit(all);
    await _savePlaylists(txn, all);
  }, library: true);
  static Future<List<Playlist>> getPlaylists() async => (await AppDatabase.instance).transaction(_playlists);
  static Future<Playlist> getFavoritesPlaylist() async => (await getPlaylists()).firstWhere((p) => p.id == Playlist.favoritesId);
  static Future<Playlist> createPlaylist(String name) async {
    final p = Playlist(id: 'pl_${DateTime.now().microsecondsSinceEpoch}_${_playlistSeq++}', name: name.trim().isEmpty ? '新建歌单' : name.trim(), tracks: []);
    await _editPlaylists((all) => all.add(p));
    return p;
  }
  static Future<Playlist> createOnlinePlaylist({required String remoteId, required String name, String? coverUrl, required List<Track> tracks}) async {
    final p = Playlist(id: remoteId, name: name, coverUrl: coverUrl, remoteId: remoteId, isOnline: true, lastSyncedAt: DateTime.now(), tracks: tracks);
    await _editPlaylists((all) { all.removeWhere((p) => p.remoteId == remoteId); all.add(p); });
    return p;
  }
  static Future<void> renamePlaylist(String id, String name) => _editPlaylists((all) {
    final i = all.indexWhere((p) => p.id == id);
    if (i < 0 || name.trim().isEmpty) return;
    all[i] = Playlist.fromMap(all[i].toMap()..['name'] = name.trim(), tracks: all[i].tracks);
  });
  static Future<void> setPlaylistCover(String id, String? path) => _editPlaylists((all) {
    final i = all.indexWhere((p) => p.id == id);
    if (i >= 0) all[i] = Playlist.fromMap(all[i].toMap()..['coverUrl'] = path, tracks: all[i].tracks);
  });
  static Future<void> deletePlaylist(String id) => _editPlaylists((all) { if (id != Playlist.favoritesId) all.removeWhere((p) => p.id == id); });
  static void _move(List<Track> tracks, int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= tracks.length) return;
    final t = tracks.removeAt(oldIndex);
    tracks.insert(newIndex.clamp(0, tracks.length), t);
  }
  static Future<void> reorderPlaylist(String id, int oldIndex, int newIndex) => _editPlaylists((all) {
    for (final p in all.where((p) => p.id == id)) { _move(p.tracks, oldIndex, newIndex); }
  });
  static Future<void> addTrackToPlaylist(String id, Track t) => addTracksToPlaylist(id, [t]);
  static Future<void> addTracksToPlaylist(String id, List<Track> tracks) => _editPlaylists((all) {
    for (final p in all.where((p) => p.id == id)) {
      final seen = p.tracks.map((t) => t.id).toSet();
      for (final t in tracks) { if (seen.add(t.id)) p.tracks.insert(0, t); }
    }
  });
  static Future<void> removeTrackFromPlaylist(String id, String trackId) => removeTracksFromPlaylist(id, [trackId]);
  static Future<void> removeTracksFromPlaylist(String id, List<String> ids) => _editPlaylists((all) {
    final removed = ids.toSet();
    for (final p in all.where((p) => p.id == id)) { p.tracks.removeWhere((t) => removed.contains(t.id)); }
  });
  static Future<bool> isFavorite(String id) async => (await getFavoritesPlaylist()).tracks.any((t) => t.id == id);
  static Future<bool> toggleFavorite(Track t) => _write((txn) async {
    final all = await _playlists(txn);
    final p = all.firstWhere((p) => p.id == Playlist.favoritesId);
    final exists = p.tracks.any((item) => item.id == t.id);
    if (exists) { p.tracks.removeWhere((item) => item.id == t.id); } else { p.tracks.insert(0, t); }
    await _savePlaylists(txn, all);
    return !exists;
  }, library: true);
  static Future<void> _saveOrder(DatabaseExecutor db, String table, List<Track> tracks) async {
    await db.delete(table);
    for (var i = 0; i < tracks.length; i++) {
      await AppDatabase.putTrack(db, tracks[i]);
      await db.insert(table, {'track_id': tracks[i].id, 'position': i});
    }
  }
  static Future<List<Track>> getRecentlyPlayed() async => _tracks(await AppDatabase.instance, 'recently_played');
  static Future<List<Track>> getDownloadedTracks() async {
    await AudioDownloadService.reconcileDownloads();
    return _tracks(await AppDatabase.instance, 'downloaded_tracks');
  }
  static Future<void> addRecentlyPlayed(Track t) => _write((txn) async {
    final all = await _tracks(txn, 'recently_played');
    all.removeWhere((item) => item.id == t.id);
    all.insert(0, t);
    await _saveOrder(txn, 'recently_played', all.take(50).toList());
  }, history: true);
  static Future<void> registerDownload(Track t, int quality, String path, int bytes) => _write((txn) async {
    await AppDatabase.putTrack(txn, t);
    await txn.insert('downloads', {'track_id': t.id, 'quality': quality, 'path': path, 'bytes': bytes}, conflictAlgorithm: ConflictAlgorithm.replace);
    final all = await _tracks(txn, 'downloaded_tracks');
    if (!all.any((item) => item.id == t.id)) { all.insert(0, t); await _saveOrder(txn, 'downloaded_tracks', all); }
  }, library: true);
  static Future<void> reorderDownloaded(int oldIndex, int newIndex) => _write((txn) async {
    final all = await _tracks(txn, 'downloaded_tracks');
    _move(all, oldIndex, newIndex);
    await _saveOrder(txn, 'downloaded_tracks', all);
  }, library: true);
  static Future<void> removeDownloadedTrack(Track t) async {
    await AudioDownloadService.deleteAllForTrack(t);
    await _write((txn) async {
      for (final table in ['downloaded_tracks', 'recently_played', 'playlist_tracks']) { await txn.delete(table, where: 'track_id = ?', whereArgs: [t.id]); }
    }, library: true, history: true);
  }
  static Future<void> updateTrackMetadata(Track t) => _write((txn) => AppDatabase.putTrack(txn, t, overwrite: true), library: true, history: true);
  static Future<List<String>> getSearchHistory() async {
    final rows = await (await AppDatabase.instance).query('search_history', orderBy: 'position');
    return rows.map((r) => r['query'] as String).toList();
  }
  static Future<List<String>> addSearchHistory(String query) async {
    final q = query.trim();
    if (q.isEmpty) return getSearchHistory();
    return _write((txn) async {
      final rows = await txn.query('search_history', orderBy: 'position');
      final all = [q, ...rows.map((r) => r['query'] as String).where((s) => s != q)].take(12).toList();
      await txn.delete('search_history');
      for (var i = 0; i < all.length; i++) { await txn.insert('search_history', {'query': all[i], 'position': i}); }
      return all;
    });
  }
  static Future<void> clearSearchHistory() => _write((txn) async { await txn.delete('search_history'); });

  static Future<bool> hasAutoCoverMatchMiss(String trackId) async {
    await AppDatabase.ensureAutoCoverMatchMissesTable();
    final rows = await (await AppDatabase.instance).query(
      'auto_cover_match_misses',
      columns: ['track_id'],
      where: 'track_id = ?',
      whereArgs: [trackId],
      limit: 1,
    );
    return rows.isNotEmpty;
  }

  static Future<void> markAutoCoverMatchMiss(String trackId) async {
    await AppDatabase.ensureAutoCoverMatchMissesTable();
    await (await AppDatabase.instance).insert(
      'auto_cover_match_misses',
      {'track_id': trackId},
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
  }

  static Future<void> clearAutoCoverMatchMiss(String trackId) async {
    await AppDatabase.ensureAutoCoverMatchMissesTable();
    await (await AppDatabase.instance).delete(
      'auto_cover_match_misses',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
  }

  static Future<void> saveLyricsReference(
    String trackId,
    LyricsReference reference, {
    List<LyricLine>? lines,
  }) => _write((txn) async {
    final existing = await txn.query('lyrics', where: 'track_id = ?', whereArgs: [trackId]);
    await txn.insert('lyrics', {
      'track_id': trackId,
      'provider': reference.provider.apiName,
      'lyric_id': reference.id,
      'title': reference.title,
      'artist': reference.artist,
      'picture_url': reference.pictureUrl,
      'lines_json': lines == null
          ? (existing.isEmpty ? null : existing.first['lines_json'])
          : jsonEncode(lines.map((line) => line.toMap()).toList()),
      'offset_ms': existing.isEmpty ? 0 : existing.first['offset_ms'],
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  });

  static Future<LyricsResult?> getCachedLyrics(String trackId) async {
    final rows = await (await AppDatabase.instance)
        .query('lyrics', where: 'track_id = ?', whereArgs: [trackId]);
    if (rows.isEmpty || rows.first['lines_json'] == null) return null;
    final reference = LyricsReference.fromMap({
      'provider': rows.first['provider'],
      'id': rows.first['lyric_id'],
      'title': rows.first['title'],
      'artist': rows.first['artist'],
      'pictureUrl': rows.first['picture_url'],
    });
    final List<LyricLine> lines;
    try {
      final raw = jsonDecode(rows.first['lines_json'] as String) as List;
      lines = raw
          .map((item) => LyricLine.fromMap(Map<String, dynamic>.from(item as Map)))
          .toList(growable: false);
    } catch (_) {
      return null;
    }
    if (lines.isEmpty) return null;
    return LyricsResult(
      source: reference.provider.apiName,
      songTitle: reference.title,
      artistName: reference.artist,
      lines: lines,
      reference: reference,
    );
  }

  static Future<Track> completeTrackEnrichment(
    Track track,
    LyricsResult result, {
    bool useReferenceCover = true,
    bool overwriteDisplayMetadata = false,
  }) async {
    // Must run before opening the transaction. Calling `instance` from inside
    // a sqflite transaction can wait on that same transaction indefinitely.
    await AppDatabase.ensureAutoCoverMatchMissesTable();
    return _write((txn) async {
      final reference = result.reference;
      if (reference == null || result.lines.isEmpty) {
        throw StateError('歌曲补全结果不完整');
      }
      final trackRows =
          await txn.query('tracks', where: 'id = ?', whereArgs: [track.id]);
      final base = overwriteDisplayMetadata || trackRows.isEmpty
          ? track
          : Track.fromMap(AppDatabase.decode(trackRows.first['payload']));
      final updated = base.copyWith(
        coverUrl: !useReferenceCover || (reference.pictureUrl ?? '').isEmpty
            ? base.coverUrl
            : reference.pictureUrl,
        musicSource: reference.provider.apiName,
        musicId: reference.id,
      );
      await AppDatabase.putTrack(txn, updated, overwrite: true);
      await txn.delete(
        'auto_cover_match_misses',
        where: 'track_id = ?',
        whereArgs: [track.id],
      );
      final old =
          await txn.query('lyrics', where: 'track_id = ?', whereArgs: [track.id]);
      await txn.insert('lyrics', {
        'track_id': track.id,
        'provider': reference.provider.apiName,
        'lyric_id': reference.id,
        'title': reference.title,
        'artist': reference.artist,
        'picture_url': reference.pictureUrl,
        'lines_json':
            jsonEncode(result.lines.map((line) => line.toMap()).toList()),
        'offset_ms': old.isEmpty ? 0 : old.first['offset_ms'],
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return updated;
    }, library: true, history: true);
  }

  static Future<LyricsReference?> getLyricsReference(String id) async {
    final rows = await (await AppDatabase.instance).query('lyrics', where: 'track_id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return LyricsReference.fromMap({
      'provider': rows.first['provider'],
      'id': rows.first['lyric_id'],
      'title': rows.first['title'],
      'artist': rows.first['artist'],
      'pictureUrl': rows.first['picture_url'],
    });
  }

  static Future<double> getLyricsOffset(String id) async {
    final rows = await (await AppDatabase.instance).query('lyrics', columns: ['offset_ms'], where: 'track_id = ?', whereArgs: [id]);
    return rows.isEmpty ? 0 : ((rows.first['offset_ms'] as int?) ?? 0) / 1000;
  }

  static Future<void> adjustLyricsOffset(String id, double delta) => _write((txn) async {
    final rows = await txn.query('lyrics', columns: ['offset_ms'], where: 'track_id = ?', whereArgs: [id]);
    if (rows.isEmpty) return;
    final current = (rows.first['offset_ms'] as int?) ?? 0;
    await txn.update('lyrics', {'offset_ms': current + (delta * 1000).round()}, where: 'track_id = ?', whereArgs: [id]);
  });

  static Future<Map<String, dynamic>?> getLyricsSelection(String id) async {
    final rows = await (await AppDatabase.instance).query('lyrics', where: 'track_id = ?', whereArgs: [id]);
    if (rows.isEmpty) return null;
    return {
      'reference': LyricsReference.fromMap({'provider': rows.first['provider'], 'id': rows.first['lyric_id'], 'title': rows.first['title'], 'artist': rows.first['artist'], 'pictureUrl': rows.first['picture_url']}).toMap(),
      'offset': ((rows.first['offset_ms'] as int?) ?? 0) / 1000,
    };
  }
  static Future<void> removeCachedLyrics(String id) => _write((txn) async {
    await txn.update('lyrics', {'lines_json': null}, where: 'track_id = ?', whereArgs: [id]);
  });
  static Future<void> replacePlaylistsAndLyrics({required List<Playlist> playlists, required Map<String, Map<String, dynamic>> lyrics, Map<String, Track> trackOverrides = const {}, BiliSession? session}) => _write((txn) async {
    final replacement = List<Playlist>.of(playlists);
    if (!replacement.any((p) => p.id == Playlist.favoritesId)) replacement.insert(0, Playlist(id: Playlist.favoritesId, name: '收藏', tracks: []));
    await _savePlaylists(txn, replacement);
    for (final entry in trackOverrides.entries) {
      final rows = await txn.query('tracks', where: 'id = ?', whereArgs: [entry.key]);
      final existing = rows.isEmpty ? entry.value : Track.fromMap(AppDatabase.decode(rows.first['payload']));
      await AppDatabase.putTrack(txn, existing.copyWith(
        title: entry.value.title,
        uploader: entry.value.uploader,
        coverUrl: entry.value.coverUrl,
        musicSource: entry.value.musicSource,
        musicId: entry.value.musicId,
      ), overwrite: true);
    }
    for (final entry in lyrics.entries) {
      final reference = LyricsReference.fromMap(Map<String, dynamic>.from(entry.value['reference'] as Map));
      await txn.insert('lyrics', {'track_id': entry.key, 'provider': reference.provider.apiName, 'lyric_id': reference.id, 'title': reference.title, 'artist': reference.artist, 'picture_url': reference.pictureUrl, 'lines_json': null, 'offset_ms': ((entry.value['offset'] as num) * 1000).round()}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (session != null) await AppDatabase.writeState('session', session.toMap(), executor: txn);
  }, library: true, history: true);
}
