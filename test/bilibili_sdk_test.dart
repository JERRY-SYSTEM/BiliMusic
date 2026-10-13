import 'dart:convert';

import 'package:bilimusic/services/bilibili_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('video info parser keeps original metadata and statistics', () {
    final tracks = BilibiliSdk.parseVideoInfoResponse(jsonEncode({
      'code': 0,
      'data': {
        'bvid': 'BV1test',
        'cid': 9,
        'title': '原始视频标题',
        'pic': 'http://i.example/cover.jpg',
        'owner': {'name': '原UP主'},
        'pubdate': 1700000000,
        'desc': '视频简介',
        'duration': 245,
        'pages': [],
        'stat': {
          'view': 101,
          'danmaku': 102,
          'like': 103,
          'coin': 104,
          'favorite': 105,
          'share': 106,
          'reply': 107,
        },
      },
    }));

    expect(tracks, hasLength(1));
    final track = tracks.single;
    expect(track.rawTitle, '原始视频标题');
    expect(track.originalUploader, '原UP主');
    expect(track.coverUrl, 'https://i.example/cover.jpg');
    expect(track.publishTime, 1700000000);
    expect(track.description, '视频简介');
    expect(track.playCount, 101);
    expect(track.replyCount, 107);
  });

  test('video info parser returns an empty list for invalid responses', () {
    expect(BilibiliSdk.parseVideoInfoResponse('{broken'), isEmpty);
    expect(
      BilibiliSdk.parseVideoInfoResponse(jsonEncode({'code': -1})),
      isEmpty,
    );
  });
}
