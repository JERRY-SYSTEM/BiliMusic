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
    final collections = list.map((item) {
      final map = Map<String, dynamic>.from(item as Map);
      return BiliFavoriteCollection(
        id: '${map['id'] ?? ''}',
        name: map['title'] as String? ?? '未命名收藏夹',
        itemCount: (map['media_count'] as num? ?? 0).toInt(),
        // `list-all.cover` is not reliable: Bilibili may populate it with
        // the first video's cover instead of the collection's own cover.
        // The canonical cover is fetched from folder/info below.
        coverUrl: null,
      );
    }).where((collection) => collection.id.isNotEmpty).toList();
    return Future.wait(collections.map((collection) async {
      final cover = await _fetchCollectionCover(session, collection.id);
      return BiliFavoriteCollection(
        id: collection.id,
        name: collection.name,
        itemCount: collection.itemCount,
        coverUrl: cover,
      );
    }));
  }

  static Future<String?> _fetchCollectionCover(
      BiliSession session, String collectionId) async {
    try {
      final json = await _get(
        '$_base/x/v3/fav/folder/info?media_id=${Uri.encodeQueryComponent(collectionId)}&web_location=333.1387',
        session.cookie,
      );
      _check(json);
      final data = json['data'];
      if (data is! Map) return null;
      return _normalizeCoverUrl(data['cover'] as String?);
    } catch (_) {
      // Cover enrichment must not prevent the user from importing a folder.
      // Returning null also deliberately selects the UI's default artwork.
      return null;
    }
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
    var cover = _normalizeCoverUrl(map['cover'] as String?) ?? '';
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
    // The favorites endpoint often omits `cover` while still returning all
    // other track metadata. Fetch the canonical video metadata in that case
    // as well, otherwise the synced playlist permanently stores an empty
    // cover URL and the UI has nothing to load.
    if (cid == 0 || title.isEmpty || uploader.isEmpty || cover.isEmpty) {
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

  static String? _normalizeCoverUrl(String? value) {
    final cover = value?.trim() ?? '';
    if (cover.isEmpty) return null;
    if (cover.startsWith('//')) return 'https:$cover';
    return cover.replaceFirst('http:', 'https:');
  }
}
