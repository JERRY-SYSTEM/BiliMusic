import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/bili_session.dart';
import 'bili_http.dart';

class BiliQrSession {
  const BiliQrSession({required this.url, required this.key});
  final String url;
  final String key;
}

enum BiliQrStatus { idle, loading, waitingForScan, waitingForConfirm, expired, failure, success }

class BiliAuthController extends ChangeNotifier {
  BiliAuthController._();
  static final BiliAuthController instance = BiliAuthController._();

  static const _passport = 'https://passport.bilibili.com';
  static const _sessionFile = 'bilibeat_bili_session.json';
  final HttpClient _client = biliHttpClient(connectionTimeout: const Duration(seconds: 15));
  Timer? _pollTimer;
  bool _polling = false;
  BiliSession? session;
  BiliQrSession? qrSession;
  BiliQrStatus status = BiliQrStatus.idle;
  String? message;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/$_sessionFile');
      if (await file.exists()) {
        session = BiliSession.decode(await file.readAsString());
        notifyListeners();
      }
    } catch (e) {
      debugPrint('BiliBeat session restore failed: $e');
    }
  }

  Future<void> startQrLogin() async {
    _cancelPolling();
    status = BiliQrStatus.loading;
    qrSession = null;
    message = null;
    notifyListeners();
    try {
      final json = await _get('$_passport/x/passport-login/web/qrcode/generate');
      _check(json);
      final data = Map<String, dynamic>.from(json['data'] as Map);
      qrSession = BiliQrSession(url: data['url'] as String? ?? '', key: data['qrcode_key'] as String? ?? '');
      status = BiliQrStatus.waitingForScan;
      notifyListeners();
      _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) => _poll());
      await _poll();
    } catch (e) {
      status = BiliQrStatus.failure;
      message = e.toString();
      notifyListeners();
    }
  }

  Future<void> _poll() async {
    final qr = qrSession;
    if (_polling || qr == null) return;
    _polling = true;
    try {
      final json = await _get('$_passport/x/passport-login/web/qrcode/poll?qrcode_key=${Uri.encodeQueryComponent(qr.key)}');
      _check(json);
      final data = Map<String, dynamic>.from(json['data'] as Map);
      final code = (data['code'] as num? ?? -1).toInt();
      message = data['message'] as String?;
      if (code == 0) {
        final cookies = _cookiesFromHeaders(json['_setCookie'] as List? ?? const []);
        final sessData = cookies['SESSDATA'] ?? '';
        final biliJct = cookies['bili_jct'] ?? '';
        final uid = cookies['DedeUserID'] ?? '';
        if (sessData.isEmpty || biliJct.isEmpty || uid.isEmpty) throw StateError('登录成功但 B 站未返回完整 Cookie');
        _cancelPolling();
        session = BiliSession(sessData: sessData, biliJct: biliJct, dedeUserId: uid, refreshToken: data['refresh_token'] as String? ?? '', cookie: cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
        await _enrichAndSave();
        status = BiliQrStatus.success;
      } else if (code == 86090) {
        status = BiliQrStatus.waitingForConfirm;
      } else if (code == 86038) {
        _cancelPolling();
        status = BiliQrStatus.expired;
      } else if (code != 86101) {
        _cancelPolling();
        status = BiliQrStatus.failure;
      }
      notifyListeners();
    } catch (e) {
      _cancelPolling();
      status = BiliQrStatus.failure;
      message = e.toString();
      notifyListeners();
    } finally {
      _polling = false;
    }
  }

  Future<void> _enrichAndSave() async {
    final current = session!;
    try {
      final json = await _get('https://api.bilibili.com/x/web-interface/nav', cookies: current.cookie);
      _check(json);
      final data = Map<String, dynamic>.from(json['data'] as Map);
      final wbi = Map<String, dynamic>.from(data['wbi_img'] as Map? ?? const {});
      session = current.copyWith(mid: (data['mid'] as num?)?.toInt(), uname: data['uname'] as String?, face: data['face'] as String?);
      // WBI keys are not required for favorite endpoints, but nav validates the session.
      if (wbi.isEmpty) debugPrint('Bilibili nav did not return wbi_img');
    } catch (_) {}
    await _save();
  }

  Future<void> logout() async {
    _cancelPolling();
    session = null;
    status = BiliQrStatus.idle;
    await _deleteSaved();
    notifyListeners();
  }

  void _cancelPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  Future<Map<String, dynamic>> _get(String url, {String? cookies}) async {
    final req = await _client.getUrl(Uri.parse(url));
    req.headers.set('Referer', 'https://www.bilibili.com');
    req.headers.set('User-Agent', kBiliUserAgent);
    if (cookies != null) req.headers.set('Cookie', cookies);
    final res = await req.close();
    final body = await res.transform(utf8.decoder).join();
    final json = Map<String, dynamic>.from(jsonDecode(body) as Map);
    if (url.contains('/qrcode/poll')) {
      json['_setCookie'] = res.headers[HttpHeaders.setCookieHeader] ?? const [];
    }
    return json;
  }

  void _check(Map<String, dynamic> json) {
    if ((json['code'] as num? ?? -1).toInt() != 0) throw StateError(json['message'] as String? ?? 'B 站请求失败');
  }

  Map<String, String> _cookiesFromHeaders(List<dynamic> headers) {
    final result = <String, String>{};
    for (final raw in headers) {
      final first = raw.toString().split(';').first;
      final index = first.indexOf('=');
      if (index > 0) result[first.substring(0, index)] = first.substring(index + 1);
    }
    return result;
  }

  Future<void> _save() async {
    final dir = await getApplicationDocumentsDirectory();
    await File('${dir.path}/$_sessionFile').writeAsString(session!.encode());
  }

  Future<void> _deleteSaved() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/$_sessionFile');
    if (await file.exists()) await file.delete();
  }
}
