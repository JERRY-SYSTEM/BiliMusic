import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../models/track.dart';

/// The single owner of the application's SQLite connection. Binary media stay
/// in the filesystem; all structured state belongs to this database.
class AppDatabase {
  AppDatabase._();

  static Future<Database>? _opening;
  static DatabaseFactory? _factory;
  static String? _path;
  static bool _wasResetForSchemaUpgrade = false;
  static final StreamController<void> _coverCacheUpdates =
      StreamController<void>.broadcast();

  static Stream<void> get coverCacheUpdateStream => _coverCacheUpdates.stream;

  static bool consumeSchemaResetNotice() {
    final value = _wasResetForSchemaUpgrade;
    _wasResetForSchemaUpgrade = false;
    return value;
  }

  static Future<Database> get instance => _opening ??= _open();

  static Future<Database> _open() async {
    try {
      final factory = _factory ?? databaseFactory;
      final path = _path ?? '${await factory.getDatabasesPath()}/bilimusic.db';
      return await factory.openDatabase(path, options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
        onCreate: (db, version) async {
          await db.execute('CREATE TABLE tracks (id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
          await db.execute('CREATE TABLE playlists (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL)');
          await db.execute('CREATE TABLE playlist_tracks (playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, track_id TEXT NOT NULL REFERENCES tracks(id), position INTEGER NOT NULL, PRIMARY KEY (playlist_id, track_id))');
          for (final table in ['downloaded_tracks', 'recently_played']) {
            await db.execute('CREATE TABLE $table (track_id TEXT PRIMARY KEY REFERENCES tracks(id), position INTEGER NOT NULL)');
          }
          await db.execute('CREATE TABLE downloads (track_id TEXT NOT NULL REFERENCES tracks(id), quality INTEGER NOT NULL, path TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY (track_id, quality))');
          await db.execute('CREATE TABLE search_history (query TEXT PRIMARY KEY, position INTEGER NOT NULL)');
          await db.execute('CREATE TABLE lyrics (track_id TEXT PRIMARY KEY, provider TEXT NOT NULL, lyric_id TEXT NOT NULL, title TEXT, artist TEXT, picture_url TEXT, lines_json TEXT, offset_ms INTEGER NOT NULL DEFAULT 0)');
          await db.execute('CREATE TABLE cover_cache (path TEXT PRIMARY KEY, track_id TEXT NOT NULL, fetch_url TEXT NOT NULL, track_payload TEXT NOT NULL)');
          await db.execute('CREATE INDEX cover_cache_by_track ON cover_cache(track_id)');
          for (final table in ['settings', 'session', 'playback_state']) {
            await db.execute('CREATE TABLE $table (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)');
          }
          await db.execute('CREATE TABLE playback_queue (kind TEXT NOT NULL, position INTEGER NOT NULL, track_id TEXT NOT NULL REFERENCES tracks(id), PRIMARY KEY (kind, position))');
          await db.execute('CREATE INDEX playlist_tracks_by_track ON playlist_tracks(track_id)');
          await db.execute('CREATE INDEX playback_queue_by_track ON playback_queue(track_id)');
          await db.insert('playlists', {'id': 'favorites', 'position': 0, 'payload': jsonEncode({'id':'favorites', 'name':'收藏', 'isOnline':false})});
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion == 4) {
            await db.execute('CREATE TABLE IF NOT EXISTS cover_cache (path TEXT PRIMARY KEY, track_id TEXT NOT NULL, fetch_url TEXT NOT NULL, track_payload TEXT NOT NULL)');
            await db.execute('CREATE INDEX IF NOT EXISTS cover_cache_by_track ON cover_cache(track_id)');
            return;
          }
          for (final table in [
            'playback_queue', 'downloads', 'downloaded_tracks',
            'recently_played', 'playlist_tracks', 'playlists', 'tracks',
            'search_history', 'lyrics', 'settings', 'session',
            'playback_state', 'cover_cache',
          ]) {
            await db.execute('DROP TABLE IF EXISTS $table');
          }
          await db.execute('CREATE TABLE tracks (id TEXT PRIMARY KEY, payload TEXT NOT NULL)');
          await db.execute('CREATE TABLE playlists (id TEXT PRIMARY KEY, position INTEGER NOT NULL, payload TEXT NOT NULL)');
          await db.execute('CREATE TABLE playlist_tracks (playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE, track_id TEXT NOT NULL REFERENCES tracks(id), position INTEGER NOT NULL, PRIMARY KEY (playlist_id, track_id))');
          for (final table in ['downloaded_tracks', 'recently_played']) {
            await db.execute('CREATE TABLE $table (track_id TEXT PRIMARY KEY REFERENCES tracks(id), position INTEGER NOT NULL)');
          }
          await db.execute('CREATE TABLE downloads (track_id TEXT NOT NULL REFERENCES tracks(id), quality INTEGER NOT NULL, path TEXT NOT NULL, bytes INTEGER NOT NULL, PRIMARY KEY (track_id, quality))');
          await db.execute('CREATE TABLE search_history (query TEXT PRIMARY KEY, position INTEGER NOT NULL)');
          await db.execute('CREATE TABLE lyrics (track_id TEXT PRIMARY KEY, provider TEXT NOT NULL, lyric_id TEXT NOT NULL, title TEXT, artist TEXT, picture_url TEXT, lines_json TEXT, offset_ms INTEGER NOT NULL DEFAULT 0)');
          await db.execute('CREATE TABLE cover_cache (path TEXT PRIMARY KEY, track_id TEXT NOT NULL, fetch_url TEXT NOT NULL, track_payload TEXT NOT NULL)');
          await db.execute('CREATE INDEX cover_cache_by_track ON cover_cache(track_id)');
          for (final table in ['settings', 'session', 'playback_state']) {
            await db.execute('CREATE TABLE $table (id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL)');
          }
          await db.execute('CREATE TABLE playback_queue (kind TEXT NOT NULL, position INTEGER NOT NULL, track_id TEXT NOT NULL REFERENCES tracks(id), PRIMARY KEY (kind, position))');
          await db.execute('CREATE INDEX playlist_tracks_by_track ON playlist_tracks(track_id)');
          await db.execute('CREATE INDEX playback_queue_by_track ON playback_queue(track_id)');
          await db.insert('playlists', {'id': 'favorites', 'position': 0, 'payload': jsonEncode({'id':'favorites', 'name':'收藏', 'isOnline':false})});
          _wasResetForSchemaUpgrade = true;
        },
      ));
    } catch (_) {
      _opening = null;
      rethrow;
    }
  }

  /// Close before changing the factory/path, including between isolated tests.
  static Future<void> configure({DatabaseFactory? factory, String? path}) async {
    await close();
    _factory = factory;
    _path = path;
  }

  static Future<void> close() async {
    final opening = _opening;
    _opening = null;
    if (opening != null) await (await opening).close();
  }

  static Map<String, dynamic> decode(Object? payload) =>
      Map<String, dynamic>.from(jsonDecode(payload as String) as Map);

  static Future<void> putTrack(DatabaseExecutor db, Track track, {bool overwrite = false}) async {
    // Ordinary playback must not replace user-edited metadata with stale data.
    await db.insert('tracks', {'id': track.id, 'payload': jsonEncode(track.toMap())},
        conflictAlgorithm: ConflictAlgorithm.ignore);
    if (overwrite) {
      await db.update('tracks', {'payload': jsonEncode(track.toMap())}, where: 'id = ?', whereArgs: [track.id]);
    }
  }

  static Future<Map<String, dynamic>?> readState(String table, {DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    final rows = await db.query(table, where: 'id = 1');
    return rows.isEmpty ? null : decode(rows.first['payload']);
  }

  static Future<void> writeState(String table, Map<String, dynamic>? value, {DatabaseExecutor? executor}) async {
    final db = executor ?? await instance;
    if (value == null) {
      await db.delete(table, where: 'id = 1');
    } else {
      await db.insert(table, {'id': 1, 'payload': jsonEncode(value)}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  }

  static Future<void> savePlayback(Map<String, dynamic> state) async {
    final db = await instance;
    await db.transaction((txn) async {
      final header = Map<String, dynamic>.from(state);
      await txn.delete('playback_queue');
      for (final kind in ['queue', 'naturalOrder']) {
        final tracks = header.remove(kind) as List;
        for (var i = 0; i < tracks.length; i++) {
          final track = Track.fromMap(Map<String, dynamic>.from(tracks[i] as Map));
          await putTrack(txn, track);
          await txn.insert('playback_queue', {'kind': kind, 'position': i, 'track_id': track.id});
        }
      }
      await writeState('playback_state', header, executor: txn);
      await pruneTracks(txn);
    });
  }

  static Future<Map<String, dynamic>?> readPlayback() async {
    final db = await instance;
    return db.transaction((txn) async {
      final state = await readState('playback_state', executor: txn);
      if (state == null) return null;
      for (final kind in ['queue', 'naturalOrder']) {
        final rows = await txn.rawQuery('SELECT t.payload FROM playback_queue q JOIN tracks t ON t.id = q.track_id WHERE q.kind = ? ORDER BY q.position', [kind]);
        state[kind] = rows.map((row) => decode(row['payload'])).toList();
      }
      return state;
    });
  }

  static Future<List<Map<String, Object?>>> downloads({String? trackId}) async {
    final db = await instance;
    return db.query('downloads', where: trackId == null ? null : 'track_id = ?', whereArgs: trackId == null ? null : [trackId]);
  }

  static Future<void> registerCoverCache(
    Track track,
    String fetchUrl,
    String path,
  ) async {
    await (await instance).insert('cover_cache', {
      'path': path,
      'track_id': track.id,
      'fetch_url': fetchUrl,
      'track_payload': jsonEncode(track.toMap()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    _coverCacheUpdates.add(null);
  }

  static Future<List<Map<String, Object?>>> coverCaches() async =>
      (await instance).query('cover_cache');

  static Future<void> forgetCoverCachesForTrack(String trackId) async {
    await (await instance).delete(
      'cover_cache',
      where: 'track_id = ?',
      whereArgs: [trackId],
    );
    _coverCacheUpdates.add(null);
  }

  static Future<void> forgetDownload(String id, int? quality) async {
    final db = await instance;
    await db.transaction((txn) async {
      await txn.delete('downloads', where: quality == null ? 'track_id = ?' : 'track_id = ? AND quality = ?', whereArgs: quality == null ? [id] : [id, quality]);
      final remaining = await txn.query('downloads', where: 'track_id = ?', whereArgs: [id], limit: 1);
      if (remaining.isEmpty) await txn.delete('downloaded_tracks', where: 'track_id = ?', whereArgs: [id]);
      await pruneTracks(txn);
    });
  }

  /// Bounded history/queues should not leave an unlimited metadata graveyard.
  static Future<void> pruneTracks(DatabaseExecutor db) async {
    const orphanWhere = 'NOT EXISTS (SELECT 1 FROM playlist_tracks WHERE track_id = tracks.id) AND NOT EXISTS (SELECT 1 FROM recently_played WHERE track_id = tracks.id) AND NOT EXISTS (SELECT 1 FROM downloaded_tracks WHERE track_id = tracks.id) AND NOT EXISTS (SELECT 1 FROM downloads WHERE track_id = tracks.id) AND NOT EXISTS (SELECT 1 FROM playback_queue WHERE track_id = tracks.id)';
    final rows = await db.query('tracks', columns: ['payload'], where: orphanWhere);
    final orphans = rows.map((row) => Track.fromMap(decode(row['payload']))).toList(growable: false);
    final registeredCoverPaths = <String>[];
    await db.rawDelete('DELETE FROM tracks WHERE $orphanWhere');
    for (final track in orphans) {
      await db.delete('lyrics', where: 'track_id = ?', whereArgs: [track.id]);
      final coverRows = await db.query(
        'cover_cache',
        columns: ['path'],
        where: 'track_id = ?',
        whereArgs: [track.id],
      );
      registeredCoverPaths.addAll(
        coverRows.map((row) => row['path'] as String),
      );
      await db.delete('cover_cache', where: 'track_id = ?', whereArgs: [track.id]);
    }
    await _deleteCoverCaches(orphans, registeredCoverPaths);
  }

  static Future<void> _deleteCoverCaches(
    List<Track> tracks,
    List<String> registeredPaths,
  ) async {
    if (tracks.isEmpty) return;
    final Directory support;
    try {
      support = await getApplicationSupportDirectory();
    } catch (_) {
      return;
    }
    final directory = Directory('${support.path}/bilimusic_covers');
    if (!await directory.exists()) return;
    for (final path in registeredPaths) {
      for (final candidate in [path, '$path.part']) {
        final file = File(candidate);
        if (await file.exists()) {
          try { await file.delete(); } catch (_) {}
        }
      }
    }
    for (final track in tracks) {
      final url = track.coverUrl;
      final uri = Uri.tryParse(url);
      if (url.isEmpty || uri == null || !uri.hasScheme) continue;
      final urls = <String>{url};
      final host = uri.host;
      final isBili = host.contains('hdslb.com') || host.contains('biliimg.com') || host.contains('bilivideo.com') || host.contains('bilibili.com');
      if (isBili && !url.contains('@')) {
        for (final size in [48, 56, 64, 72, 80, 96, 128, 256, 512]) {
          urls.add('$url@${size}w_${size}h_1e_1c.webp');
        }
      }
      for (final cachedUrl in urls) {
        final key = md5.convert(utf8.encode(cachedUrl)).toString();
        for (final name in ['img_$key.img', 'img_$key.img.part', 'system_$key.jpg', 'system_$key.jpg.part']) {
          final file = File('${directory.path}/$name');
          if (await file.exists()) {
            try { await file.delete(); } catch (_) {}
          }
        }
      }
    }
  }
}
