import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/track.dart';
import '../models/audio_quality.dart';
import 'bili_http.dart';
import 'fingerprint_service.dart';
import 'wbi_signer.dart';

class BilibiliSdk {
  static const String _baseUrl = 'https://api.bilibili.com';

  /// 音乐 partition. Covers 原创音乐 / 翻唱 / 演奏 / VOCALOID / 音乐现场 / MV /
  /// 音乐综合 — everything a music player has any business showing.
  static const int _musicZoneId = 3;
  static final HttpClient _httpClient =
      biliHttpClient(connectionTimeout: const Duration(seconds: 15),
          maxConnectionsPerHost: 10);

  static final RegExp _htmlTagRegex = RegExp(r'<[^>]+>');

  static Future<String?> _httpGet(String rawUrl, {String? cookies}) async {
    try {
      final req = await _httpClient.getUrl(Uri.parse(rawUrl));
      req.headers.set('Referer', 'https://www.bilibili.com');
      req.headers.set('User-Agent', kBiliUserAgent);
      if (cookies != null && cookies.isNotEmpty) {
        req.headers.set('Cookie', cookies);
      }
      final res = await req.close();
      if (res.statusCode == 200) {
        return await res.transform(utf8.decoder).join();
      } else {
        await res.drain<void>();
        debugPrint('Bilibili HTTP ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('Bilibili HTTP fetch error: $e');
    }
    return null;
  }

  // Extract BV or AV ID from input query
  static String? extractBvOrAvId(String input) {
    final trimmed = input.trim();
    final bvMatch = RegExp(r'(BV[a-zA-Z0-9]{10})', caseSensitive: false).firstMatch(trimmed);
    if (bvMatch != null) return bvMatch.group(1);

    final avMatch = RegExp(r'av(\d+)', caseSensitive: false).firstMatch(trimmed);
    // The API's `aid` parameter expects bare digits, not the "av" prefix.
    if (avMatch != null) return avMatch.group(1);

    return null;
  }

  // Fetch Video Info by BV or AV ID
  static Future<List<Track>> fetchVideoInfo(String idInput) async {
    final id = extractBvOrAvId(idInput) ?? idInput.trim();
    final paramKey = id.toLowerCase().startsWith('bv') ? 'bvid' : 'aid';
    final url = '$_baseUrl/x/web-interface/view?$paramKey=$id';

    try {
      final body = await _httpGet(url);
      if (body != null) {
        final json = jsonDecode(body);
        if (json['code'] == 0 && json['data'] != null) {
          final data = json['data'];
          final bvid = data['bvid'] as String;
          final title = data['title'] as String;
          var pic = (data['pic'] as String? ?? '').replaceAll('http:', 'https:');
          if (pic.startsWith('//')) pic = 'https:$pic';
          final owner = data['owner'] ?? {};
          final uploader = owner['name'] as String? ?? '未知UP主';
          final totalDuration = data['duration'] as int? ?? 0;
          final pages = data['pages'] as List? ?? [];

          if (pages.isEmpty) {
            return [
              Track(
                id: '${bvid}_p1',
                bvid: bvid,
                cid: data['cid'] as int? ?? 0,
                title: title,
                rawTitle: title,
                uploader: uploader,
                coverUrl: pic,
                duration: totalDuration,
              )
            ];
          }

          return pages.map((p) {
            final cid = p['cid'] as int;
            final pageNo = p['page'] as int;
            final partTitle = p['part'] as String? ?? title;
            final pageDuration = p['duration'] as int? ?? totalDuration;

            return Track(
              id: '${bvid}_p$pageNo',
              bvid: bvid,
              cid: cid,
              title: pages.length > 1 ? '$title - P$pageNo: $partTitle' : title,
              rawTitle: title,
              uploader: uploader,
              coverUrl: pic,
              duration: pageDuration,
            );
          }).toList();
        }
      }
    } catch (e) {
      debugPrint('Bilibili SDK error: $e');
    }

    return [];
  }

  // Fetch audio stream URL (prefers standard MP4/M4A container for native MediaPlayer compatibility)
  static Future<Map<String, String>?> fetchAudioStream(String bvid, int cid) async {
    final options = await fetchAudioQualities(bvid, cid);
    if (options.isEmpty) return null;
    final item = options.first;
    return {'url': item.url, 'quality': item.label, 'qualityId': '${item.id ?? 0}'};
  }

  static Future<List<AudioQualityOption>> fetchAudioQualities(String bvid, int cid, {String? cookies, int? preferredQuality}) async {
    try {
      if (cid == 0) {
        final infoList = await fetchVideoInfo(bvid);
        if (infoList.isNotEmpty) {
          cid = infoList.first.cid;
        }
      }
      if (cid == 0) return const <AudioQualityOption>[];

      // fnval=16 requests DASH; the response still carries a plain `durl`
      // MP4/M4A stream for most videos, which we prefer for native playback.
      final rawParams = <String, dynamic>{
        'bvid': bvid,
        'cid': cid,
        'fnval': 16,
        'fnver': 0,
        'fourk': 1,
        'qn': preferredQuality ?? 80,
      };

      final signed = await WbiSigner.signParams(rawParams);
      final queryStr = signed.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}').join('&');
      final url = '$_baseUrl/x/player/wbi/playurl?$queryStr';

      final body = await _httpGet(url, cookies: cookies);
      if (body != null) {
        final json = jsonDecode(body);
        if (json['code'] == 0 && json['data'] != null) {
          final durlList = json['data']?['durl'] as List? ?? [];
          if (durlList.isNotEmpty) {
            final durl = Map<String, dynamic>.from(durlList.first as Map);
            final streamUrl = durl['url'] as String?;
            if (streamUrl != null && streamUrl.isNotEmpty) {
              return [AudioQualityOption(id: 80, label: '高品质 AAC/M4A', url: streamUrl.replaceAll('http:', 'https:'), bandwidth: 320000)];
            }
          }
          final audioList = json['data']?['dash']?['audio'] as List? ?? [];
          final result = <AudioQualityOption>[];
          for (final raw in audioList) {
            final map = Map<String, dynamic>.from(raw as Map);
            var streamUrl = map['baseUrl'] as String? ?? map['base_url'] as String?;
            if (streamUrl == null || streamUrl.isEmpty) {
              final backup = map['backupUrl'];
              if (backup is List && backup.isNotEmpty) streamUrl = backup.first as String?;
            }
            if (streamUrl == null || streamUrl.isEmpty) continue;
            final id = (map['id'] as num?)?.toInt();
            final bandwidth = (map['bandwidth'] as num?)?.toInt() ?? 0;
            final label = id == 30251 ? 'Hi-Res / FLAC' : id == 30280 ? '192k' : id == 30232 ? '132k' : '${(bandwidth / 1000).round()}k';
            result.add(AudioQualityOption(id: id, label: label, url: streamUrl.replaceAll('http:', 'https:'), bandwidth: bandwidth, requiresLogin: id == 30251 || id == 30280));
          }
          result.sort((a, b) => b.bandwidth.compareTo(a.bandwidth));
          return result;
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch audio stream: $e');
    }

    return const <AudioQualityOption>[];
  }

  // Search Bilibili catalog for ANY query
  static Future<List<Track>> search(String query, {int page = 1}) async {
    if (query.trim().isEmpty) return [];

    // A BV number or a link never goes through the keyword search: asking for
    // something by id means you want exactly it, whatever zone it lives in.
    final directId = extractBvOrAvId(query);
    if (directId != null) {
      return await fetchVideoInfo(directId);
    }

    // Music zone first. If that comes back empty — no matches there, or an API
    // that quietly rejects the filter — fall back to an unfiltered search
    // rather than telling the user their song does not exist.
    final musical = await _searchOnce(query, musicOnly: true, page: page);
    if (musical.isNotEmpty) return musical;
    return _searchOnce(query, musicOnly: false, page: page);
  }

  static Future<List<Track>> _searchOnce(String query,
      {required bool musicOnly, int page = 1}) async {
    try {
      // Obtain buvid3/buvid4 device fingerprint (required by B站 anti-bot)
      final cookieStr = await FingerprintService.getCookieString();

      // Get dm_img risk-control simulation parameters
      final dmParams = FingerprintService.getDmImgParams();

      final rawParams = <String, dynamic>{
        'search_type': 'video',
        'keyword': query.trim(),
        'page': page,
        'order': 'totalrank',
        // This is a music player: a keyword search that returns lectures,
        // gameplay and news is noise.
        if (musicOnly) 'tids': _musicZoneId,
        // dm_img 风控参数 — 缺少会导致 -352 / 412
        ...dmParams,
      };

      final signed = await WbiSigner.signParams(rawParams);
      final queryStr = signed.entries.map((e) => '${e.key}=${Uri.encodeComponent(e.value.toString())}').join('&');
      final searchUrl = '$_baseUrl/x/web-interface/wbi/search/type?$queryStr';

      var body = await _httpGet(searchUrl, cookies: cookieStr);
      // -352 / 412 are B站 risk-control codes; check them on the decoded JSON
      // rather than string-matching (which breaks on whitespace variations).
      if (_riskControlled(body)) {
        body = null;
      }
      if (body == null) {
        // Fallback: standard web search API
        final fallbackUrl = '$_baseUrl/x/web-interface/search/type'
            '?search_type=video'
            '${musicOnly ? "&tids=$_musicZoneId" : ""}'
            '&page=$page'
            '&keyword=${Uri.encodeComponent(query.trim())}';
        body = await _httpGet(fallbackUrl, cookies: cookieStr);
      }

      if (body != null) {
        final json = jsonDecode(body);

        final dynamic rawResult = json['data']?['result'];
        List? resultsList;
        if (rawResult is List) {
          resultsList = rawResult;
        } else if (rawResult is Map && rawResult['video'] is List) {
          resultsList = rawResult['video'] as List;
        }

        if (resultsList != null) {
          final tracks = <Track>[];

          for (final item in resultsList) {
            final bvid = item['bvid'] as String?;
            if (bvid == null || bvid.isEmpty) continue;

            final rawTitle = item['title'] as String? ?? '';
            final cleanTitle = rawTitle.replaceAll(_htmlTagRegex, '');
            final author = item['author'] as String? ?? 'UP主';
            final pic = (item['pic'] as String? ?? '').replaceAll('http:', 'https:');

            int durationSec = 0;
            final durRaw = item['duration'];
            if (durRaw is String) {
              final parts = durRaw.split(':').map((e) => int.tryParse(e) ?? 0).toList();
              if (parts.length == 2) {
                durationSec = parts[0] * 60 + parts[1];
              } else if (parts.length == 3) {
                durationSec = parts[0] * 3600 + parts[1] * 60 + parts[2];
              }
            } else if (durRaw is int) {
              durationSec = durRaw;
            }

            // Search results are always the video's first part, and the search
            // API does not return a cid — hence the page-based id: keying on
            // cid would have produced `bvid_0` here and `bvid_<cid>` for the
            // same video opened by BV number, i.e. two entries for one song
            // with separate download state.
            tracks.add(Track(
              id: '${bvid}_p1',
              bvid: bvid,
              cid: item['cid'] as int? ?? 0,
              title: cleanTitle,
              rawTitle: cleanTitle,
              uploader: author,
              coverUrl: pic.startsWith('//') ? 'https:$pic' : pic,
              duration: durationSec,
            ));
          }

          if (tracks.isNotEmpty) return tracks;
        }
      }
    } catch (e) {
      debugPrint('Bilibili search error: $e');
    }

    return [];
  }

  /// True when the response is B站's risk-control rejection (-352 / 412),
  /// which should trigger the unfiltered fallback search API.
  static bool _riskControlled(String? body) {
    if (body == null) return false;
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final code = decoded['code'];
        return code == -352 || code == 412;
      }
    } catch (_) {
      // Not JSON at all — not a clean rejection, treat as a normal response.
    }
    return false;
  }
}
