import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:bilimusic/models/track.dart';
import 'package:bilimusic/services/app_database.dart';
import 'package:bilimusic/services/app_transfer_service.dart';
import 'package:bilimusic/services/bili_auth_service.dart';
import 'package:bilimusic/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late BiliAuthController auth;
  late AppTransferService service;
  late Uint8List backup;
  setUp(() async {
    await AppDatabase.configure(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    auth = BiliAuthController.forTesting();
    service = AppTransferService(auth: auth,
      fetchVideoInfo: (bvid) async => [Track(id: bvid, bvid: bvid, cid: 11, title: 'network', rawTitle: 'network', uploader: 'network', coverUrl: '', duration: 12)],
      fetchOnlineTracks: (_, __) async => throw const SocketException('offline'),
    );
    // Current strict backup shape.
    backup = Uint8List.fromList(utf8.encode(jsonEncode({
      'schemaVersion': 2, 'exportedAt': '2026-09-28T08:00:00.000Z',
      'session': {'sessData':'test', 'biliJct':'csrf', 'dedeUserId':'1', 'refreshToken':'', 'cookie':'SESSDATA=test'},
      'playlists': [
        {'id':'favorites', 'name':'收藏', 'isOnline':false, 'tracks':[{'id':'BVtest', 'bvid':'BVtest', 'cid':11, 'title':'我的歌名', 'author':'我的歌手', 'cover':['netease','123'], 'lyrics':['netease','123',0.5]}]},
        {'id':'42', 'name':'在线', 'isOnline':true, 'tracks':[{'id':'BVtest', 'bvid':'BVtest', 'cid':11, 'title':'我的歌名', 'author':'我的歌手', 'cover':['netease','123'], 'lyrics':['netease','123',0.5]}]},
      ],
    })));
  });
  tearDown(() async { auth.dispose(); await AppDatabase.close(); });

  test('old backup previews, imports selectively, deduplicates and round trips', () async {
    final preview = service.previewImport(backup);
    expect(preview.hasSession, isTrue);
    expect(preview.favoriteTrackCount, 1);
    const selection = AppImportSelection(importSession: false, importFavorites: true, playlistIds: {});
    await service.importBytes(bytes: backup, selection: selection);
    await service.importBytes(bytes: backup, selection: selection);
    expect(auth.session, isNull);
    expect(await DatabaseService.getPlaylists(), hasLength(1));
    final favorites = await DatabaseService.getFavoritesPlaylist();
    expect(favorites.tracks, hasLength(1));
    expect(favorites.tracks.single.title, '我的歌名');
    final lyricSelection = await DatabaseService.getLyricsSelection('BVtest');
    expect(lyricSelection, isNotNull);
    expect(lyricSelection!['offset'], 0.5);
    final exported = await service.buildExportJson();
    final exportedMap = jsonDecode(exported) as Map;
    expect(exportedMap['schemaVersion'], 3);
    final exportedTrack = (((exportedMap['playlists'] as List).first as Map)['tracks'] as List).first as Map;
    expect(exportedTrack['lyrics'], ['netease', '123', 0.5]);
    await DatabaseService.removeTrackFromPlaylist('favorites', 'BVtest');
    await service.importBytes(bytes: Uint8List.fromList(utf8.encode(exported)), selection: selection);
    expect((await DatabaseService.getFavoritesPlaylist()).tracks.single.uploader, '我的歌手');
  });

  test('online sync failure falls back to backup and commits selected session', () async {
    final result = await service.importBytes(bytes: backup, selection: const AppImportSelection(importSession: true, importFavorites: false, playlistIds: {'42'}));
    expect(result.failedOnlinePlaylistCount, 1);
    expect(result.trackCount, 1);
    expect((await DatabaseService.getFavoritesPlaylist()).tracks, isEmpty);
    final online = (await DatabaseService.getPlaylists()).last;
    expect(online.isOnline, isTrue);
    expect(online.lastSyncedAt, isNull);
    expect(online.tracks.single.title, '我的歌名');
    expect(auth.session!.dedeUserId, '1');
    expect((await AppDatabase.readState('session'))!['dedeUserId'], '1');
  });

  test('failed commit neither changes library nor publishes imported login', () async {
    final db = await AppDatabase.instance;
    await db.execute("CREATE TRIGGER fail_import BEFORE INSERT ON session BEGIN SELECT RAISE(ABORT, 'failure'); END");
    await expectLater(service.importBytes(bytes: backup, selection: const AppImportSelection(importSession: true, importFavorites: true, playlistIds: {})), throwsA(isA<DatabaseException>()));
    expect(auth.session, isNull);
    expect((await DatabaseService.getFavoritesPlaylist()).tracks, isEmpty);
    expect(await DatabaseService.getLyricsSelection('BVtest'), isNull);
  });
}
