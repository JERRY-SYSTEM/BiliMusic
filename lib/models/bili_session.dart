import 'dart:convert';

class BiliSession {
  const BiliSession({
    required this.sessData,
    required this.biliJct,
    required this.dedeUserId,
    required this.refreshToken,
    required this.cookie,
    this.mid,
    this.uname,
    this.face,
  });

  final String sessData;
  final String biliJct;
  final String dedeUserId;
  final String refreshToken;
  final String cookie;
  final int? mid;
  final String? uname;
  final String? face;

  bool get isLoggedIn =>
      sessData.isNotEmpty && biliJct.isNotEmpty && dedeUserId.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'sessData': sessData,
        'biliJct': biliJct,
        'dedeUserId': dedeUserId,
        'refreshToken': refreshToken,
        'cookie': cookie,
        'mid': mid,
        'uname': uname,
        'face': face,
      };

  factory BiliSession.fromMap(Map<String, dynamic> map) => BiliSession(
        sessData: map['sessData'] as String? ?? '',
        biliJct: map['biliJct'] as String? ?? '',
        dedeUserId: map['dedeUserId'] as String? ?? '',
        refreshToken: map['refreshToken'] as String? ?? '',
        cookie: map['cookie'] as String? ?? '',
        mid: (map['mid'] as num?)?.toInt(),
        uname: map['uname'] as String?,
        face: map['face'] as String?,
      );

  String encode() => jsonEncode(toMap());

  factory BiliSession.decode(String value) =>
      BiliSession.fromMap(Map<String, dynamic>.from(jsonDecode(value) as Map));

  BiliSession copyWith({int? mid, String? uname, String? face}) => BiliSession(
        sessData: sessData,
        biliJct: biliJct,
        dedeUserId: dedeUserId,
        refreshToken: refreshToken,
        cookie: cookie,
        mid: mid ?? this.mid,
        uname: uname ?? this.uname,
        face: face ?? this.face,
      );
}
