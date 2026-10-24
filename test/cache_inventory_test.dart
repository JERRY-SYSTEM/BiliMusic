import 'dart:convert';
import 'dart:io';

import 'package:bilimusic/models/track.dart';
import 'package:bilimusic/services/app_database.dart';
import 'package:bilimusic/services/cache_inventory.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('other cleanup preserves offline media and excludes playlist artwork', () async {
    final root = await Directory.systemTemp.createTemp('cache-inventory-');
    final docs = await Directory('${root.path}/docs').create();
    final support = await Directory('${root.path}/support').create();
    final temp = await Directory('${root.path}/temp').create();
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => switch (call.method) {
          'getApplicationDocumentsDirectory' => docs.path,
          'getApplicationSupportDirectory' => support.path,
          'getTemporaryDirectory' => temp.path,
          _ => null,
        });
    await AppDatabase.configure(factory: databaseFactoryFfiNoIsolate, path: '${root.path}/db');
    try {
      final db = await AppDatabase.instance;
      const track = Track(id: 'song', bvid: 'BVtest', cid: 1, title: 'song',
          rawTitle: 'song', uploader: 'artist', coverUrl: 'https://example.com/song.jpg', duration: 30);
      await AppDatabase.putTrack(db, track);
      Future<File> file(String path, int size) async {
        final result = File(path);
        await result.parent.create(recursive: true);
        return result.writeAsBytes(List.filled(size, 1));
      }
      final audio = await file('${docs.path}/bilimusic_audio/audio_song.m4a', 100);
      await db.insert('downloads', {'track_id': track.id, 'quality': 0, 'path': audio.path, 'bytes': 100});
      final cover = await file('${support.path}/bilimusic_covers/song.img', 20);
      await AppDatabase.registerCoverCache(track, track.coverUrl, cover.path);
      await db.insert('lyrics', {'track_id': track.id, 'provider': 'test', 'lyric_id': '1', 'lines_json': '[]'});
      final part = await file('${cover.path}.part', 200);
      final scratch = await file('${temp.path}/nested/work.tmp', 300);
      final key = md5.convert(utf8.encode('https://example.com/playlist.jpg')).toString();
      final playlist = await file('${support.path}/bilimusic_covers/img_$key.img', 400);
      await db.update('playlists', {'payload': jsonEncode({'id': 'favorites', 'name': 'favorites', 'coverUrl': 'https://example.com/playlist.jpg'})});
      final permanent = await file('${support.path}/bilimusic_playlist_covers/cover.img', 500);
      final inventory = await CacheInventory.load([]);
      expect(inventory.map((bucket) => bucket.bytes), [500, 122]);
      expect(inventory.first.isOther, isTrue);
      expect(inventory.first.files.map((f) => f.path), unorderedEquals([part.path, scratch.path]));
      for (final f in inventory.first.files) { await f.delete(); }
      expect(await audio.exists(), isTrue);
      expect(await cover.exists(), isTrue);
      expect(await playlist.exists(), isTrue);
      expect(await permanent.exists(), isTrue);
      expect((await db.query('lyrics')).single['lines_json'], '[]');
      final remaining = await CacheInventory.load([]);
      expect(remaining.single.track?.id, track.id);
      expect(remaining.single.bytes, 122);
    } finally {
      await AppDatabase.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      await root.delete(recursive: true);
    }
  });
}
