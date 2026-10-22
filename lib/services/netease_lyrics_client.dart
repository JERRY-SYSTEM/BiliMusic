import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'netease_eapi.dart';

class _NetEaseSession {
  _NetEaseSession(this.cookies) : expires = DateTime.now().add(const Duration(days: 10));

  final Map<String, String> cookies;
  final DateTime expires;
}

/// A separate anonymous music-catalog session; it never uses Bilibili cookies.
/// Registration and lyric requests share the same EAPI identity and cookies.
class NetEaseLyricsClient {
  NetEaseLyricsClient(this._client);

  final HttpClient _client;
  Future<_NetEaseSession>? _session;
  static const _appVersion = '3.1.3.203419';
  static const _timeout = Duration(seconds: 12);

  Future<Map<String, dynamic>> lyrics(String id) async {
    // Refresh an expired/rejected anonymous session once, without falling back
    // to LRC until both attempts have finished.
    for (var attempt = 0; attempt < 2; attempt++) {
      final session = await _getSession();
      final data = await _send('/eapi/song/lyric/v1', {
        'id': int.parse(id), 'lv': '-1', 'tv': '-1', 'rv': '-1',
        'yv': '-1', 'ytv': '-1', 'yrv': '-1',
      }, session.cookies);
      final code = (data['code'] as num?)?.toInt();
      if (code == 200) {
        return data;
      }
      if (attempt == 0 && (code == 301 || code == 401 || code == -460)) {
        _session = null;
        continue;
      }
      throw FormatException('NetEase YRC API code $code');
    }
    throw const FormatException('NetEase anonymous session rejected');
  }

  Future<_NetEaseSession> _getSession() async {
    final pending = _session ??= _register();
    try {
      final session = await pending;
      if (!session.expires.isAfter(DateTime.now())) {
        if (identical(_session, pending)) {
          _session = null;
        }
        return await _getSession();
      }
      return session;
    } catch (_) {
      if (identical(_session, pending)) {
        _session = null;
      }
      rethrow;
    }
  }

  Future<_NetEaseSession> _register() async {
    final random = Random.secure();
    String hex(int count) => List.generate(count,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join();
    final deviceId = hex(24).toUpperCase();
    final mac = List.generate(6, (_) => hex(1).toUpperCase()).join(':');
    final label = String.fromCharCodes(List.generate(8, (_) => 65 + random.nextInt(26)));
    final cookies = <String, String>{
      'os': 'pc', 'appver': _appVersion, 'deviceId': deviceId,
      'osver': 'Microsoft-Windows-10--build-22631-64bit',
      'clientSign': '$mac@@@$label@@@@@@${hex(32)}',
      'channel': 'netease', 'mode': 'Desktop',
    };
    final key = ascii.encode(r'3go8&$8*3*3h0k(2)2');
    final deviceBytes = utf8.encode(deviceId);
    final digest = md5.convert(List<int>.generate(deviceBytes.length,
      (i) => deviceBytes[i] ^ key[i % key.length]));
    final username = base64Encode(utf8.encode('$deviceId ${base64Encode(digest.bytes)}'));
    final data = await _send('/eapi/register/anonimous', {'username': username}, cookies);
    if (data['code'] != 200 || (cookies['MUSIC_A'] ?? '').isEmpty) {
      throw FormatException('NetEase anonymous registration failed (code ${data['code']})');
    }
    return _NetEaseSession(cookies);
  }

  Future<Map<String, dynamic>> _send(String path, Map<String, dynamic> params,
      Map<String, String> cookies) async {
    final request = await _client.postUrl(Uri.https('interface.music.163.com', path)).timeout(_timeout);
    request.headers.contentType = ContentType('application', 'x-www-form-urlencoded');
    request.headers.set('Accept', '*/*');
    request.headers.set('Referer', 'https://music.163.com/');
    request.headers.set('Origin', 'orpheus://orpheus');
    request.headers.set('User-Agent',
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/91.0.4472.164 NeteaseMusicDesktop/$_appVersion');
    request.headers.set('mconfig-info', jsonEncode({
      'IuRPVVmc3WWul9fT': {'version': 733184, 'appver': _appVersion},
    }));
    request.headers.set('Cookie', cookies.entries.map((entry) => '${entry.key}=${entry.value}').join('; '));
    final header = <String, dynamic>{
      for (final name in ['os', 'appver', 'deviceId', 'osver', 'clientSign']) name: cookies[name],
      'requestId': DateTime.now().millisecondsSinceEpoch.toString(),
    };
    final payload = NetEaseEapi.encode(path.replaceFirst('/eapi/', '/api/'), {
      ...params, 'e_r': true, 'header': jsonEncode(header),
    });
    request.write('params=$payload');
    try {
      final response = await request.close().timeout(_timeout);
      final bytes = await response.fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk))
          .timeout(_timeout);
      if (response.statusCode != 200) {
        throw HttpException('NetEase $path HTTP ${response.statusCode}');
      }
      for (final cookie in response.cookies) {
        cookies[cookie.name] = cookie.value;
      }
      return NetEaseEapi.decodeResponse(bytes);
    } catch (_) {
      request.abort();
      rethrow;
    }
  }
}
