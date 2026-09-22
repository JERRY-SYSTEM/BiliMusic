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
    final p = Playlist(id: 'online_$remoteId', name: name, coverUrl: coverUrl, remoteId: remoteId, isOnline: true, lastSyncedAt: DateTime.now(), tracks: tracks);
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
  static Future<void> _putLyrics(DatabaseExecutor db, String id, LyricsResult lyrics) async {
    final rows = await db.rawQuery('SELECT COALESCE(MAX(position), -1) + 1 AS next FROM lyrics');
    await db.insert('lyrics', {'track_id': id, 'payload': jsonEncode(lyrics.toMap()), 'position': rows.first['next']}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  static Future<void> cacheLyrics(String id, LyricsResult lyrics) => _write((txn) async {
    if (lyrics.source == 'none') { await txn.delete('lyrics', where: 'track_id = ?', whereArgs: [id]); return; }
    await _putLyrics(txn, id, lyrics);
    await txn.rawDelete('DELETE FROM lyrics WHERE track_id IN (SELECT track_id FROM lyrics ORDER BY position DESC LIMIT -1 OFFSET 200)');
  });
  static Future<LyricsResult?> getCachedLyrics(String id) async {
    final rows = await (await AppDatabase.instance).query('lyrics', where: 'track_id = ?', whereArgs: [id]);
    return rows.isEmpty ? null : LyricsResult.fromMap(AppDatabase.decode(rows.first['payload']));
  }
  static Future<void> removeCachedLyrics(String id) => _write((txn) async { await txn.delete('lyrics', where: 'track_id = ?', whereArgs: [id]); });
  static Future<Map<String, int>> lyricsSizes() async {
    final rows = await (await AppDatabase.instance).rawQuery('SELECT track_id, length(CAST(payload AS BLOB)) AS bytes FROM lyrics');
    return {for (final row in rows) row['track_id'] as String: row['bytes'] as int};
  }
  static Future<Map<String, LyricsResult>> getManualLyrics(Set<String> ids) async {
    final rows = await (await AppDatabase.instance).query('lyrics');
    final result = <String, LyricsResult>{};
    for (final row in rows) {
      if (!ids.contains(row['track_id'])) continue;
      final lyrics = LyricsResult.fromMap(AppDatabase.decode(row['payload']));
      if (lyrics.isManual) result[row['track_id'] as String] = lyrics;
    }
    return result;
  }
  static Future<void> replacePlaylistsAndManualLyrics({required List<Playlist> playlists, required Map<String, LyricsResult> manualLyrics, Map<String, Track> trackOverrides = const {}, BiliSession? session}) => _write((txn) async {
    final replacement = List<Playlist>.of(playlists);
    if (!replacement.any((p) => p.id == Playlist.favoritesId)) replacement.insert(0, Playlist(id: Playlist.favoritesId, name: '收藏', tracks: []));
    await _savePlaylists(txn, replacement);
    for (final entry in trackOverrides.entries) {
      final rows = await txn.query('tracks', where: 'id = ?', whereArgs: [entry.key]);
      final existing = rows.isEmpty ? entry.value : Track.fromMap(AppDatabase.decode(rows.first['payload']));
      await AppDatabase.putTrack(txn, existing.copyWith(title: entry.value.title, uploader: entry.value.uploader), overwrite: true);
    }
    for (final entry in manualLyrics.entries) { await _putLyrics(txn, entry.key, entry.value); }
    if (session != null) await AppDatabase.writeState('session', session.toMap(), executor: txn);
  }, library: true, history: true);
}
