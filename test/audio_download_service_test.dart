import 'dart:async';
import 'dart:io';

import 'package:bilimusic/models/track.dart';
import 'package:bilimusic/services/app_database.dart';
import 'package:bilimusic/services/audio_download_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Directory directory;
  late HttpServer server;
  late StreamSubscription<HttpRequest> requests;
  late Future<void> Function(HttpRequest) respond;
  late Track track;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('bilimusic-download-test-');
    await AppDatabase.configure(factory: databaseFactoryFfiNoIsolate, path: inMemoryDatabasePath);
    AudioDownloadService.configureForTesting(directory.path);
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    respond = (request) async {
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.contentLength = 2048;
      request.response.add(List.filled(2048, 1));
      await request.response.close();
    };
    requests = server.listen((request) async { await respond(request); });
    track = Track(id: 'BVtest_p1', bvid: 'BVtest', cid: 1, title: 'test', rawTitle: 'test', uploader: 'artist', coverUrl: '', duration: 20, audioUrl: 'http://127.0.0.1:${server.port}/audio');
  });
  tearDown(() async {
    await requests.cancel();
    await server.close(force: true);
    await AppDatabase.close();
    await directory.delete(recursive: true);
  });

  test('complete file is registered once without sidecars', () async {
    final paths = await Future.wait([AudioDownloadService.ensureDownloaded(track), AudioDownloadService.ensureDownloaded(track)]);
    expect(paths[0], paths[1]);
    final rows = await AppDatabase.downloads();
    expect(rows, hasLength(1));
    expect(rows.single['bytes'], 2048);
    expect(await File(paths.first).length(), 2048);
    expect(directory.listSync().whereType<File>().map((f) => f.uri.pathSegments.last), ['audio_BVtest_p1.m4a']);
  });

  test('non-audio response cannot create a completed download', () async {
    respond = (request) async {
      request.response.headers.contentType = ContentType.json;
      request.response.write('{"error":"expired"}');
      await request.response.close();
    };
    await expectLater(AudioDownloadService.ensureDownloaded(track), throwsException);
    expect(await AppDatabase.downloads(), isEmpty);
  });

  test('interrupted download keeps partial data and resumes with Range', () async {
    final partial = File('${directory.path}/audio_BVtest_p1.m4a.part');
    await partial.writeAsBytes(List.filled(1024, 1));
    expect(await AudioDownloadService.isDownloaded(track), isFalse);
    respond = (request) async {
      expect(request.headers.value(HttpHeaders.rangeHeader), 'bytes=1024-');
      request.response.statusCode = HttpStatus.partialContent;
      request.response.headers.contentType = ContentType('audio', 'mp4');
      request.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes 1024-2047/2048');
      request.response.contentLength = 1024;
      request.response.add(List.filled(1024, 2));
      await request.response.close();
    };
    final path = await AudioDownloadService.ensureDownloaded(track);
    expect(await File(path).length(), 2048);
    expect(await partial.exists(), isFalse);
    expect((await AppDatabase.downloads()).single['bytes'], 2048);
  });

  test('database failure after file finalization does not report completion', () async {
    final db = await AppDatabase.instance;
    await db.execute("CREATE TRIGGER fail_download BEFORE INSERT ON downloads BEGIN SELECT RAISE(ABORT, 'failure'); END");
    await expectLater(AudioDownloadService.ensureDownloaded(track), throwsA(isA<DatabaseException>()));
    expect(await AppDatabase.downloads(), isEmpty);
    expect(await AudioDownloadService.isDownloaded(track), isFalse);
    // The complete but unregistered file is safe to clean as an orphan.
    expect(await File('${directory.path}/audio_BVtest_p1.m4a').exists(), isTrue);
  });
}
