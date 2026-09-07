import 'dart:convert';
import 'dart:typed_data';

import 'package:bilibeat/services/app_transfer_service.dart';
import 'package:bilibeat/theme/app_theme.dart';
import 'package:bilibeat/widgets/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, dynamic> _validBackup() => {
      'schemaVersion': 1,
      'exportedAt': '2026-09-06T08:00:00.000Z',
      'session': {
        'sessData': 'secret-session',
        'biliJct': 'secret-csrf',
        'dedeUserId': '123',
        'refreshToken': 'secret-refresh',
        'cookie': 'SESSDATA=secret-session',
      },
      'playlists': [
        {
          'id': 'favorites',
          'name': '收藏',
          'isOnline': false,
          'tracks': [
            {
              'id': 'BV1test_p1',
              'bvid': 'BV1test',
              'cid': 11,
              'title': '自定义歌名',
              'uploader': '自定义歌手',
            },
          ],
        },
        {
          'id': 'online_42',
          'name': '在线歌单',
          'isOnline': true,
          'remoteId': '42',
          'tracks': [],
        },
      ],
      'manualLyrics': {
        'BV1test_p1': {
          'source': 'user',
          'songTitle': '自定义歌名',
          'artistName': '自定义歌手',
          'lines': [
            {'time': 0.0, 'text': '手动歌词', 'translation': null},
          ],
          'isManual': true,
        },
      },
    };

void main() {
  const service = AppTransferService();

  test('previews session, favorites and online playlists without secrets', () {
    final preview = service.previewImport(_bytes(_validBackup()));

    expect(preview.hasSession, isTrue);
    expect(preview.favoriteTrackCount, 1);
    expect(preview.localPlaylistCount, 0);
    expect(preview.onlinePlaylistCount, 1);
    expect(preview.playlists, hasLength(1));
    expect(preview.playlists.single.id, 'online_42');
    expect(preview.playlists.single.isOnline, isTrue);
    expect(preview.toString(), isNot(contains('secret-session')));
  });

  test('rejects backups from a newer schema', () {
    final backup = _validBackup()..['schemaVersion'] = 999;

    expect(
      () => service.previewImport(_bytes(backup)),
      throwsA(
        isA<AppTransferException>().having(
          (error) => error.message,
          'message',
          contains('更新版本'),
        ),
      ),
    );
  });

  test('accepts an unresolved CID when the part id is available', () {
    final backup = _validBackup();
    final playlists = backup['playlists'] as List;
    final track = (playlists.first['tracks'] as List).first as Map;
    track['cid'] = 0;
    expect(service.previewImport(_bytes(backup)).favoriteTrackCount, 1);
  });

  test('rejects duplicate tracks instead of importing duplicate entries', () {
    final backup = _validBackup();
    final playlists = backup['playlists'] as List;
    final tracks = playlists.first['tracks'] as List;
    tracks.add(Map<String, dynamic>.from(tracks.first as Map));
    expect(() => service.previewImport(_bytes(backup)),
        throwsA(isA<AppTransferException>()));
  });

  test('rejects a part id belonging to a different video', () {
    final backup = _validBackup();
    final playlists = backup['playlists'] as List;
    final track = (playlists.first['tracks'] as List).first as Map;
    track['id'] = 'BVother_p1';
    expect(() => service.previewImport(_bytes(backup)),
        throwsA(isA<AppTransferException>()));
  });

  test('rejects non-manual lyrics in a backup', () {
    final backup = _validBackup();
    final lyrics = backup['manualLyrics'] as Map<String, dynamic>;
    final entry = lyrics['BV1test_p1'] as Map<String, dynamic>;
    entry['isManual'] = false;

    expect(
      () => service.previewImport(_bytes(backup)),
      throwsA(
        isA<AppTransferException>().having(
          (error) => error.message,
          'message',
          contains('非手动歌词'),
        ),
      ),
    );
  });

  test('rejects duplicate playlist ids', () {
    final backup = _validBackup();
    final playlists = backup['playlists'] as List<dynamic>;
    playlists.add(Map<String, dynamic>.from(playlists.first as Map));

    expect(
      () => service.previewImport(_bytes(backup)),
      throwsA(
        isA<AppTransferException>().having(
          (error) => error.message,
          'message',
          contains('重复的歌单 ID'),
        ),
      ),
    );
  });

  testWidgets('设置页在缓存管理上方显示数据导入导出入口', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(ThemeMode.dark, AppColors.accent),
        home: const SettingsPage(),
      ),
    );

    final transfer = find.text('数据导入导出');
    final cache = find.text('缓存管理');
    expect(transfer, findsOneWidget);
    expect(cache, findsOneWidget);
    expect(tester.getTopLeft(transfer).dy, lessThan(tester.getTopLeft(cache).dy));

    await tester.tap(transfer);
    await tester.pumpAndSettle();
    expect(find.text('导出数据'), findsOneWidget);
    expect(find.text('导入数据'), findsOneWidget);
  });
}
