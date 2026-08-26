import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/bili_favorite_collection.dart';
import '../models/bili_session.dart';
import '../models/track.dart';
import 'bili_http.dart';
import 'bilibili_sdk.dart';

class BiliFavoritesService {
  static const _base = 'https://api.bilibili.com';
  static final HttpClient _client = biliHttpClient(connectionTimeout: const Duration(seconds: 15));

  static Future<List<BiliFavoriteCollection>> fetchCollections(BiliSession session) async {
    final mid = session.mid ?? int.tryParse(session.dedeUserId) ?? 0;
    if (!session.isLoggedIn || mid <= 0) throw StateError('请先登录 B 站账号');
    final json = await _get('$_base/x/v3/fav/folder/created/list-all?up_mid=$mid&web_location=333.1387', session.cookie);
    _check(json);
    final data = Map<String, dynamic>.from(json['data'] as Map? ?? const {});
    final list = data['list'] as List? ?? const [];
    return list.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return BiliFavoriteCollection(
        id: '${map['id'] ?? ''}',
        name: map['title'] as String? ?? '未命名收藏夹',
        itemCount: (map['media_count'] as num? ?? 0).toInt(),
        coverUrl: map['cover'] as String?,
      );
    }).where((collection) => collection.id.isNotEmpty).toList();
  }

  static Future<List<Track>> fetchTracks(BiliSession session, String collectionId) async {
    final tracks = <Track>[];
    var page = 1;
    while (true) {
      final json = await _get('$_base/x/v3/fav/resource/list?media_id=${Uri.encodeQueryComponent(collectionId)}&platform=web&pn=$page&ps=20', session.cookie);
      _check(json);
      final data = Map<String, dynamic>.from(json['data'] as Map? ?? const {});
      final medias = data['medias'] as List? ?? const [];
      for (final item in medias) {
        final track = await _mapTrack(Map<String, dynamic>.from(item as Map));
        if (track != null) tracks.add(track);
      }
      if (medias.isEmpty || data['has_more'] != true) break;
      page++;
    }
    return tracks;
  }

  static Future<Track?> _mapTrack(Map<String, dynamic> map) async {
    if ((map['type'] as num? ?? 2).toInt() != 2) return null;
    var bvid = map['bvid'] as String? ?? map['bv_id'] as String? ?? '';
    var title = map['title'] as String? ?? '';
    var cover = (map['cover'] as String? ?? '').replaceFirst('http:', 'https:');
    final upper = map['upper'] is Map ? Map<String, dynamic>.from(map['upper'] as Map) : const <String, dynamic>{};
    var uploader = upper['name'] as String? ?? '';
    var duration = (map['duration'] as num? ?? 0).toInt();
    var cid = (map['cid'] as num? ?? 0).toInt();
    if (bvid.isEmpty) {
      final aid = map['aid'] ?? map['id'];
      if (aid == null) return null;
      final info = await BilibiliSdk.fetchVideoInfo('av$aid');
      if (info.isEmpty) return null;
      return info.first;
    }
    if (cid == 0 || title.isEmpty || uploader.isEmpty) {
      final info = await BilibiliSdk.fetchVideoInfo(bvid);
      if (info.isNotEmpty) {
        final first = info.first;
        cid = cid == 0 ? first.cid : cid;
        title = title.isEmpty ? first.title : title;
        uploader = uploader.isEmpty ? first.uploader : uploader;
        cover = cover.isEmpty ? first.coverUrl : cover;
        duration = duration == 0 ? first.duration : duration;
      }
    }
    if (cid == 0 || bvid.isEmpty) return null;
    return Track(id: '${bvid}_p1', bvid: bvid, cid: cid, title: title.isEmpty ? '未知曲目' : title, rawTitle: title, uploader: uploader.isEmpty ? '未知UP主' : uploader, coverUrl: cover, duration: duration);
  }

  static Future<Map<String, dynamic>> _get(String url, String cookies) async {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('Referer', 'https://www.bilibili.com');
    req.headers.set('User-Agent', kBiliUserAgent);
    req.headers.set('Cookie', cookies);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    return Map<String, dynamic>.from(jsonDecode(body) as Map);
  }

  static void _check(Map<String, dynamic> json) {
    final code = (json['code'] as num? ?? -1).toInt();
    if (code != 0) throw StateError(json['message'] as String? ?? '收藏夹请求失败');
  }
}
