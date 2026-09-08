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
      fetchVideoInfo: (bvid) async => [Track(id: '${bvid}_p1', bvid: bvid, cid: 11, title: 'network', rawTitle: 'network', uploader: 'network', coverUrl: '', duration: 12)],
      fetchOnlineTracks: (_, __) async => throw const SocketException('offline'),
    );
    // This is the exact v1 shape emitted by BiliBeat; there is no new envelope.
    backup = Uint8List.fromList(utf8.encode(jsonEncode({
      'schemaVersion': 1, 'exportedAt': '2026-09-06T08:00:00.000Z',
      'session': {'sessData':'test', 'biliJct':'csrf', 'dedeUserId':'1', 'refreshToken':'', 'cookie':'SESSDATA=test'},
      'playlists': [
        {'id':'favorites', 'name':'收藏', 'isOnline':false, 'tracks':[{'id':'BVtest_p1', 'bvid':'BVtest', 'cid':11, 'title':'我的歌名', 'uploader':'我的歌手'}]},
        {'id':'online_42', 'name':'在线', 'isOnline':true, 'remoteId':'42', 'tracks':[{'id':'BVtest_p1', 'bvid':'BVtest', 'cid':11, 'title':'我的歌名', 'uploader':'我的歌手'}]},
      ],
      'manualLyrics': {'BVtest_p1':{'source':'user', 'isManual':true, 'songTitle':'我的歌词', 'lines':[]}},
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
    expect((await DatabaseService.getCachedLyrics('BVtest_p1'))!.isManual, isTrue);
    final exported = await service.buildExportJson();
    expect((jsonDecode(exported) as Map)['schemaVersion'], 1);
    await DatabaseService.removeTrackFromPlaylist('favorites', 'BVtest_p1');
    await service.importBytes(bytes: Uint8List.fromList(utf8.encode(exported)), selection: selection);
    expect((await DatabaseService.getFavoritesPlaylist()).tracks.single.uploader, '我的歌手');
  });

  test('online sync failure falls back to backup and commits selected session', () async {
    final result = await service.importBytes(bytes: backup, selection: const AppImportSelection(importSession: true, importFavorites: false, playlistIds: {'online_42'}));
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
    expect(await DatabaseService.getCachedLyrics('BVtest_p1'), isNull);
  });
}
