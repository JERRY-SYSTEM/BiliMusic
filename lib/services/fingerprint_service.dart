import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'bili_http.dart';

/// Service to obtain Bilibili device fingerprints (buvid3/buvid4)
/// and generate dm_img risk-control simulation parameters.
///
/// B站搜索 API 强制要求 buvid3 Cookie 和 dm_img 风控参数，
/// 缺少会导致搜索返回空结果 (-352 / 412)。
class FingerprintService {
  static final HttpClient _client = biliHttpClient();

  static String _buvid3 = '';
  static String _buvid4 = '';
  static DateTime? _cacheTime;

  static const String _spiUrl =
      'https://api.bilibili.com/x/frontend/finger/spi';

  /// Get cached or fresh buvid3 and buvid4 values.
  /// Calls the B站 fingerprint SPI endpoint.
  static Future<Map<String, String>> getBuvid() async {
    final now = DateTime.now();
    if (_buvid3.isNotEmpty &&
        _cacheTime != null &&
        now.difference(_cacheTime!).inHours < 1) {
      return {'buvid3': _buvid3, 'buvid4': _buvid4};
    }

    try {
      final req = await _client.getUrl(Uri.parse(_spiUrl));
      req.headers.set('Referer', 'https://www.bilibili.com');
      req.headers.set('User-Agent', kBiliUserAgent);
      final res = await req.close();
      if (res.statusCode != 200) {
        await res.drain<void>();
        throw Exception('fingerprint HTTP ${res.statusCode}');
      }
      final body = await res.transform(utf8.decoder).join();

      final json = jsonDecode(body);
      if (json['code'] == 0 && json['data'] != null) {
        _buvid3 = json['data']['b_3'] as String? ?? '';
        _buvid4 = json['data']['b_4'] as String? ?? '';
        // A code-0 response with an empty b_3 is a failure too: caching it
        // would make every search re-fetch, and using it produces no cookie.
        if (_buvid3.isNotEmpty) {
          _cacheTime = now;
          return {'buvid3': _buvid3, 'buvid4': _buvid4};
        }
      }
    } catch (e) {
      debugPrint('FingerprintService: failed to get buvid: $e');
    }

    // Fallback: generate a random buvid3 in UUID-like format
    if (_buvid3.isEmpty) {
      _buvid3 = _generateRandomBuvid3();
      _buvid4 = '';
      _cacheTime = now;
    }

    return {'buvid3': _buvid3, 'buvid4': _buvid4};
  }

  /// Build the Cookie string for B站 API requests.
  static Future<String> getCookieString() async {
    final buvid = await getBuvid();
    final parts = <String>[];
    if (buvid['buvid3']?.isNotEmpty == true) {
      parts.add('buvid3=${buvid['buvid3']}');
    }
    if (buvid['buvid4']?.isNotEmpty == true) {
      parts.add('buvid4=${buvid['buvid4']}');
    }
    return parts.join('; ');
  }

  /// Generate dm_img risk-control parameters that mimic browser behavior.
  /// These are required by B站's anti-bot system for search requests.
  static Map<String, String> getDmImgParams() {
    return {
      'dm_img_list': '[]',
      'dm_img_str': _randomDmImgStr(),
      'dm_cover_img_str': _randomDmImgStr(),
      'dm_img_inter': '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}',
    };
  }

  /// Generate a random string simulating dm_img_str / dm_cover_img_str.
  static String _randomDmImgStr() {
    const chars = 'V2ViR0wgMS4w';
    final rng = Random();
    final len = 8 + rng.nextInt(5);
    return List.generate(len, (_) => chars[rng.nextInt(chars.length)]).join();
  }

  /// Generate a random buvid3 in UUID v4-like format as fallback.
  static String _generateRandomBuvid3() {
    final rng = Random();
    String hex(int len) =>
        List.generate(len, (_) => rng.nextInt(16).toRadixString(16)).join();
    return '${hex(8)}-${hex(4)}-${hex(4)}-${hex(4)}-${hex(12)}infoc';
  }
}
