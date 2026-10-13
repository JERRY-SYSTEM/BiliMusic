import 'dart:convert';
import 'dart:typed_data';

import 'package:bilimusic/services/app_transfer_service.dart';
import 'package:bilimusic/theme/app_theme.dart';
import 'package:bilimusic/widgets/settings_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _bytes(Map<String, dynamic> json) =>
    Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, dynamic> _validBackup() => {
      'schemaVersion': 3,
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
              'id': 'test',
              'bvid': 'BV1test',
              'cid': 11,
              'title': '自定义歌名',
              'author': '自定义歌手',
              'cover': ['netease', '123'],
              'lyrics': ['netease', '123', 0.5],
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
    };

void main() {
  const service = AppTransferService();

  test('rejects backups from a newer schema', () {
    final backup = _validBackup()..['schemaVersion'] = 999;

    expect(
      () => service.previewImport(_bytes(backup)),
      throwsA(
        isA<AppTransferException>().having(
          (error) => error.message,
          'message',
          contains('不匹配'),
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
