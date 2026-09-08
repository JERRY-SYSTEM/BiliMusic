import 'dart:convert';
import 'dart:io';

import 'package:bilimusic/models/bili_session.dart';
import 'package:bilimusic/models/lyric_line.dart';
import 'package:bilimusic/models/playlist.dart';
import 'package:bilimusic/models/track.dart';
import 'package:bilimusic/services/app_database.dart';
import 'package:bilimusic/services/app_settings_service.dart';
import 'package:bilimusic/services/audio_download_service.dart';
import 'package:bilimusic/services/bili_auth_service.dart';
import 'package:bilimusic/services/database_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

Track track(String id) => Track(id: id, bvid: 'BVtest', cid: 1, title: id,
    rawTitle: id, uploader: 'artist', coverUrl: '', duration: 30);
const manual = LyricsResult(source: 'user', lines: [], isManual: true, songTitle: '手动歌词');
const session = BiliSession(sessData: 'test', biliJct: 'csrf', dedeUserId: '1', refreshToken: '', cookie: 'SESSDATA=test');

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bilimusic-db-test-');
    await AppDatabase.configure(factory: databaseFactoryFfiNoIsolate, path: '${directory.path}/bilimusic.db');
    AudioDownloadService.configureForTesting(directory.path);
  });
  tearDown(() async {
    await AppDatabase.close();
    await directory.delete(recursive: true);
  });

  test('fresh database ignores legacy files, persists order and detached reads', () async {
    final legacy = File('${directory.path}/bilibeat_playlists.json');
    await legacy.writeAsString('[{"id":"old"}]');
    expect((await DatabaseService.getPlaylists()).map((p) => p.id), ['favorites']);
    final p = await DatabaseService.createPlaylist(' test ');
    await DatabaseService.addTracksToPlaylist(p.id, [track('BV_p1'), track('BV_p2'), track('BV_p1')]);
    await DatabaseService.reorderPlaylist(p.id, 0, 1);
    final detached = await DatabaseService.getPlaylists();
    detached.last.tracks.clear();
    await AppDatabase.close();
    final restored = (await DatabaseService.getPlaylists()).last;
    expect(restored.name, 'test');
    expect(restored.tracks.map((t) => t.id), ['BV_p1', 'BV_p2']);
    expect(await legacy.readAsString(), '[{"id":"old"}]');
    expect(directory.listSync().whereType<File>().where((f) => f.path.endsWith('.json')), hasLength(1));
  });

  test('concurrent edits serialize; metadata is consistent in every relation', () async {
    final t = track('a');
    final p = await DatabaseService.createPlaylist('p');
    await Future.wait([DatabaseService.addTrackToPlaylist(p.id, t), DatabaseService.addTrackToPlaylist(p.id, track('b'))]);
    await DatabaseService.addRecentlyPlayed(t);
    final audio = File('${directory.path}/audio_a.m4a');
    await audio.writeAsBytes([1, 2, 3]);
    await DatabaseService.registerDownload(t, 0, audio.path, 3);
    await AppDatabase.savePlayback({'queue': [t.toMap()], 'naturalOrder': [t.toMap()], 'positionMs': 7000, 'currentIndex': 0, 'shuffle': false, 'loopMode': 'all'});
    await DatabaseService.updateTrackMetadata(t.copyWith(title: 'edited'));
    await DatabaseService.addRecentlyPlayed(t); // Stale playback data must not undo edits.
    expect((await DatabaseService.getRecentlyPlayed()).single.title, 'edited');
    expect((await DatabaseService.getDownloadedTracks()).single.title, 'edited');
    expect((await DatabaseService.getPlaylists()).last.tracks, hasLength(2));
    expect((await DatabaseService.getPlaylists()).last.tracks.firstWhere((t) => t.id == 'a').title, 'edited');
    expect(((await AppDatabase.readPlayback())!['queue'] as List).single['title'], 'edited');
  });

  test('download qualities survive reopening and missing files reconcile', () async {
    final t = track('multi');
    for (final quality in [30280, 30232]) {
      final audio = File('${directory.path}/audio_multi_$quality.m4a');
      await audio.writeAsBytes([1, 2, 3]);
      await DatabaseService.registerDownload(t, quality, audio.path, 3);
    }
    await AppDatabase.close();
    expect(await AppDatabase.downloads(), hasLength(2));
    await AudioDownloadService.delete(t, quality: 30280);
    expect(await DatabaseService.getDownloadedTracks(), hasLength(1));
    expect(await AudioDownloadService.isAnyQualityDownloaded(t), isTrue);
    await File('${directory.path}/audio_multi_30232.m4a').delete();
    expect(await DatabaseService.getDownloadedTracks(), isEmpty);
    expect(await AppDatabase.downloads(), isEmpty);
  });

  test('unregistered and partial files never become downloaded tracks', () async {
    await File('${directory.path}/audio_orphan.m4a').writeAsBytes([1, 2]);
    await File('${directory.path}/audio_orphan.m4a.part').writeAsBytes([1]);
    expect(await DatabaseService.getDownloadedTracks(), isEmpty);
    expect(await AudioDownloadService.isDownloadedById('orphan'), isFalse);
    await AudioDownloadService.deleteAllForTrack(track('orphan'));
    expect(await File('${directory.path}/audio_orphan.m4a').exists(), isFalse);
  });

  test('delete matches complete part ids and leaves sibling parts intact', () async {
    for (final id in ['BV_p1', 'BV_p10']) {
      final file = File('${directory.path}/audio_$id.m4a.part');
      await file.writeAsBytes([1]);
    }
    await AudioDownloadService.deleteAllForTrack(track('BV_p1'));
    expect(await File('${directory.path}/audio_BV_p10.m4a.part').exists(), isTrue);
  });

  test('search/history limits and lyrics bytes persist across reopen', () async {
    for (var i = 0; i < 55; i++) { await DatabaseService.addRecentlyPlayed(track('$i')); }
    for (var i = 0; i < 15; i++) { await DatabaseService.addSearchHistory('$i'); }
    await DatabaseService.addSearchHistory(' 14 ');
    await DatabaseService.cacheLyrics('54', manual);
    await AppDatabase.close();
    expect(await DatabaseService.getRecentlyPlayed(), hasLength(50));
    expect(await (await AppDatabase.instance).query('tracks'), hasLength(50));
    expect(await DatabaseService.getSearchHistory(), hasLength(12));
    expect((await DatabaseService.getSearchHistory()).first, '14');
    expect((await DatabaseService.lyricsSizes())['54'], utf8.encode(jsonEncode(manual.toMap())).length);
    await DatabaseService.cacheLyrics('54', const LyricsResult(source: 'none', lines: []));
    await AppDatabase.close();
    expect(await DatabaseService.getCachedLyrics('54'), isNull);
  });

  test('settings, session, shuffle and duplicate queue entries survive restart', () async {
    final settings = AppSettingsService.forTesting();
    final auth = BiliAuthController.forTesting();
    await Future.wait([settings.setThemeMode('light'), settings.setAccentValue(123), settings.setDefaultAudioQuality(30232)]);
    await auth.importSession(session);
    final a = track('a').toMap(), b = track('b').toMap();
    await AppDatabase.savePlayback({'queue': [b, a, b], 'naturalOrder': [a, b, b], 'currentIndex': 1, 'positionMs': 12000, 'shuffle': true, 'loopMode': 'one'});
    await AppDatabase.close();
    final restored = AppSettingsService.forTesting();
    final restoredAuth = BiliAuthController.forTesting();
    await restored.initialize();
    await restoredAuth.initialize();
    expect(restored.themeMode, 'light');
    expect(restored.accentValue, 123);
    expect(restored.defaultAudioQuality, 30232);
    expect(restoredAuth.session!.dedeUserId, '1');
    final playback = (await AppDatabase.readPlayback())!;
    expect((playback['queue'] as List).map((t) => t['id']), ['b', 'a', 'b']);
    expect(playback['shuffle'], isTrue);
    expect(playback['positionMs'], 12000);
    await restoredAuth.logout();
    expect(await AppDatabase.readState('session'), isNull);
    settings.dispose(); restored.dispose(); auth.dispose(); restoredAuth.dispose();
  });

  test('import transaction rolls back all tables and emits no success event', () async {
    await DatabaseService.cacheLyrics('old', manual);
    await AppDatabase.writeState('session', session.toMap());
    final db = await AppDatabase.instance;
    await db.execute("CREATE TRIGGER fail_import BEFORE INSERT ON session BEGIN SELECT RAISE(ABORT, 'injected failure'); END");
    var updates = 0;
    final subscription = DatabaseService.libraryUpdateStream.listen((_) => updates++);
    await expectLater(DatabaseService.replacePlaylistsAndManualLyrics(
      playlists: [Playlist(id: 'import', name: 'import', tracks: [track('new')])],
      manualLyrics: {'new': manual}, session: session,
    ), throwsA(isA<DatabaseException>()));
    expect((await DatabaseService.getPlaylists()).map((p) => p.id), ['favorites']);
    expect(await DatabaseService.getCachedLyrics('new'), isNull);
    expect(await DatabaseService.getCachedLyrics('old'), isNotNull);
    expect(await db.query('tracks'), isEmpty);
    expect((await AppDatabase.readState('session'))!['dedeUserId'], '1');
    expect(updates, 0);
    await subscription.cancel();
  });

  test('failed settings write leaves memory unchanged and a later save works', () async {
    final settings = AppSettingsService.forTesting();
    await settings.initialize();
    var notifications = 0;
    settings.addListener(() => notifications++);
    final db = await AppDatabase.instance;
    await db.execute("CREATE TRIGGER fail_settings BEFORE INSERT ON settings BEGIN SELECT RAISE(ABORT, 'failure'); END");
    await expectLater(settings.setThemeMode('light'), throwsA(isA<DatabaseException>()));
    expect(settings.themeMode, 'dark');
    expect(notifications, 0);
    await db.execute('DROP TRIGGER fail_settings');
    await settings.setThemeMode('light');
    expect(settings.themeMode, 'light');
    expect(notifications, 1);
    settings.dispose();
  });
}
