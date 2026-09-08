import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'app_database.dart';

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
  @visibleForTesting
  BiliAuthController.forTesting();
  static final BiliAuthController instance = BiliAuthController._();

  static const _passport = 'https://passport.bilibili.com';
  final HttpClient _client = biliHttpClient(connectionTimeout: const Duration(seconds: 15));
  Timer? _pollTimer;
  bool _polling = false;
  BiliSession? session;
  BiliQrSession? qrSession;
  BiliQrStatus status = BiliQrStatus.idle;
  String? message;
  Future<void>? _initializeFuture;

  Future<void> initialize() => _initializeFuture ??= _restoreSession();

  Future<void> _restoreSession() async {
    try {
      final saved = await AppDatabase.readState('session');
      session = saved == null ? null : BiliSession.fromMap(saved);
      notifyListeners();
    } catch (_) {
      _initializeFuture = null;
      rethrow;
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
        final candidate = BiliSession(sessData: sessData, biliJct: biliJct, dedeUserId: uid, refreshToken: data['refresh_token'] as String? ?? '', cookie: cookies.entries.map((e) => '${e.key}=${e.value}').join('; '));
        await _enrichAndSave(candidate);
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

  Future<void> _enrichAndSave(BiliSession current) async {
    var enriched = current;
    try {
      final json = await _get('https://api.bilibili.com/x/web-interface/nav', cookies: current.cookie);
      _check(json);
      final data = Map<String, dynamic>.from(json['data'] as Map);
      final wbi = Map<String, dynamic>.from(data['wbi_img'] as Map? ?? const {});
      enriched = current.copyWith(mid: (data['mid'] as num?)?.toInt(), uname: data['uname'] as String?, face: data['face'] as String?);
      // WBI keys are not required for favorite endpoints, but nav validates the session.
      if (wbi.isEmpty) debugPrint('Bilibili nav did not return wbi_img');
    } catch (_) {}
    await AppDatabase.writeState('session', enriched.toMap());
    session = enriched;
  }

  Future<void> logout() async {
    _cancelPolling();
    await AppDatabase.writeState('session', null);
    session = null;
    status = BiliQrStatus.idle;
    notifyListeners();
  }

  /// Replaces the current persisted login with a session from a local backup.
  ///
  /// Validation happens before touching the existing session so a malformed
  /// backup cannot accidentally log the user out. Cookie values are never
  /// included in thrown errors or debug output.
  Future<void> importSession(BiliSession imported) async {
    if (!imported.isLoggedIn || imported.cookie.trim().isEmpty) {
      throw const FormatException('备份中的登录信息不完整');
    }
    await initialize();
    await AppDatabase.writeState('session', imported.toMap());
    acceptCommittedSession(imported);
  }

  /// Publish a session already committed by the backup import transaction.
  void acceptCommittedSession(BiliSession imported) {
    _cancelPolling();
    session = imported;
    status = BiliQrStatus.success;
    qrSession = null;
    message = null;
    notifyListeners();
  }

  void _cancelPolling() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  @override
  void dispose() {
    _cancelPolling();
    _client.close(force: true);
    super.dispose();
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

}
