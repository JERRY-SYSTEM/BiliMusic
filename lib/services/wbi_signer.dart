import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'bili_http.dart';

class WbiSigner {
  static final HttpClient _client = biliHttpClient();

  static final RegExp _stripChars = RegExp(r"[!'()*]");

  static const List<int> mixinKeyEncTab = [
    46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
    33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
    61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
    36, 20, 34, 44, 52
  ];

  static String _cachedImgKey = '';
  static String _cachedSubKey = '';
  static DateTime? _cacheTime;

  static String _getMixinKey(String orig) {
    return mixinKeyEncTab.map((n) => orig[n]).join().substring(0, 32);
  }

  static Future<Map<String, dynamic>> signParams(Map<String, dynamic> params) async {
    final keys = await _getWbiKeys();
    final mixinKey = _getMixinKey(keys['imgKey']! + keys['subKey']!);
    final currTime = (DateTime.now().millisecondsSinceEpoch / 1000).round();

    final newParams = Map<String, dynamic>.from(params);
    newParams['wts'] = currTime;

    final sortedKeys = newParams.keys.toList()..sort();
    final queryParts = <String>[];

    for (final k in sortedKeys) {
      var val = newParams[k].toString();
      val = val.replaceAll(_stripChars, '');
      queryParts.add('${Uri.encodeComponent(k)}=${Uri.encodeComponent(val)}');
    }

    final queryStr = queryParts.join('&');
    final wbiSign = md5.convert(utf8.encode(queryStr + mixinKey)).toString();

    newParams['w_rid'] = wbiSign;
    return newParams;
  }

  static Future<Map<String, String>> _getWbiKeys() async {
    if (_cacheTime != null && DateTime.now().difference(_cacheTime!).inHours < 12) {
      if (_cachedImgKey.isNotEmpty && _cachedSubKey.isNotEmpty) {
        return {'imgKey': _cachedImgKey, 'subKey': _cachedSubKey};
      }
    }

    try {
      final req = await _client.getUrl(Uri.parse('https://api.bilibili.com/x/web-interface/nav'));
      req.headers.set('User-Agent',
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36');
      req.headers.set('Referer', 'https://www.bilibili.com/');
      final res = await req.close();
      if (res.statusCode == 200) {
        final body = await res.transform(utf8.decoder).join();
        final json = jsonDecode(body);
        final wbiImg = json['data']?['wbi_img'];
        if (wbiImg != null) {
          final imgUrl = wbiImg['img_url'] as String? ?? '';
          final subUrl = wbiImg['sub_url'] as String? ?? '';

          _cachedImgKey = imgUrl.split('/').last.split('.').first;
          _cachedSubKey = subUrl.split('/').last.split('.').first;
          _cacheTime = DateTime.now();

          return {'imgKey': _cachedImgKey, 'subKey': _cachedSubKey};
        }
      }
    } catch (e) {
      debugPrint('Failed to fetch WBI keys: $e');
    }

    // Fallback static keys if network unavailable. B站 rotates these, so a
    // stale pair signs requests that the API rejects — make that degraded
    // state visible instead of silently serving bad signatures.
    debugPrint('WbiSigner: live WBI keys unavailable, using static fallback. '
        'Signed requests may be rejected until the live keys can be fetched.');
    return {
      'imgKey': '7057082772594611a917024e0f065363',
      'subKey': '0a6e0388df634f1ca668482436d4001c',
    };
  }
}
