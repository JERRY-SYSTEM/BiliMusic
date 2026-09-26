import 'package:flutter/foundation.dart';

/// One playable Bilibili audio part.
///
/// Deliberately narrow: fields that were written but never read (uploaderFace,
/// quality, localFilePath, addedAt, and an `isDownloaded` flag that duplicated
/// — and could contradict — what is actually on disk) have been removed.
/// Download state has exactly one source of truth: [AudioDownloadService].
class Track {
  /// `bvid_p<page>`, uniquely naming one part of one video. This is the
  /// identity used for equality, de-duplication and on-disk file naming.
  ///
  /// Deliberately *not* keyed on cid: search results do not carry one, so a
  /// cid-based id gave the same song two identities — `bvid_0` from search and
  /// `bvid_<cid>` from a BV number — with separate library entries and
  /// separate downloads. The page number is known on both paths.
  final String id;

  static String idFor(String bvid, [int page = 1]) {
    final compact = bvid.startsWith('BV1') ? bvid.substring(3) : bvid;
    return page == 1 ? compact : '${compact}_p$page';
  }
  final String bvid;
  final int cid;
  final String title;
  /// The B站 raw video title, immutable after fetch. Metadata edits overwrite
  /// [title] (the display name) but must never touch this field — 智能识别
  /// parses THIS, or a polluted display title would be re-parsed forever.
  final String rawTitle;
  /// Original uploader returned by Bilibili. Unlike [uploader], this is not
  /// changed by the metadata editor and is used by the read-only info page.
  final String? originalUploader;
  final String uploader;
  final String coverUrl;
  /// Music catalog identity used to restore lyrics and artwork without
  /// searching again. Empty strings mean that enrichment is still pending.
  final String musicSource;
  final String musicId;
  final int duration; // in seconds
  final String? audioUrl;
  final int? qualityId;
  final int? publishTime;
  final String? description;
  final int? playCount;
  final int? danmakuCount;
  final int? likeCount;
  final int? coinCount;
  final int? favoriteCount;
  final int? shareCount;
  final int? replyCount;

  const Track({
    required this.id,
    required this.bvid,
    required this.cid,
    required this.title,
    required this.rawTitle,
    this.originalUploader,
    required this.uploader,
    required this.coverUrl,
    this.musicSource = '',
    this.musicId = '',
    required this.duration,
    this.audioUrl,
    this.qualityId,
    this.publishTime,
    this.description,
    this.playCount,
    this.danmakuCount,
    this.likeCount,
    this.coinCount,
    this.favoriteCount,
    this.shareCount,
    this.replyCount,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'bvid': bvid,
      'cid': cid,
      'title': title,
      'rawTitle': rawTitle,
      'originalUploader': originalUploader,
      'uploader': uploader,
      'coverUrl': coverUrl,
      'musicSource': musicSource,
      'musicId': musicId,
      'duration': duration,
      'audioUrl': audioUrl,
      'qualityId': qualityId,
      'publishTime': publishTime,
      'description': description,
      'playCount': playCount,
      'danmakuCount': danmakuCount,
      'likeCount': likeCount,
      'coinCount': coinCount,
      'favoriteCount': favoriteCount,
      'shareCount': shareCount,
      'replyCount': replyCount,
    };
  }

  /// Shared mapping for SQLite records and network-derived track values.
  factory Track.fromMap(Map<String, dynamic> map) {
    final musicSource = map['musicSource'] as String;
    final musicId = map['musicId'] as String;
    if (musicSource.isEmpty != musicId.isEmpty ||
        (musicSource.isNotEmpty &&
            !const {'netease', 'kugou', 'tencent'}.contains(musicSource))) {
      throw const FormatException('歌曲来源与 ID 无效');
    }
    return Track(
      id: map['id'] as String,
      bvid: map['bvid'] as String,
      cid: map['cid'] as int,
      title: map['title'] as String,
      rawTitle: map['rawTitle'] as String,
      originalUploader: map['originalUploader'] as String?,
      uploader: map['uploader'] as String,
      coverUrl: map['coverUrl'] as String,
      musicSource: musicSource,
      musicId: musicId,
      duration: map['duration'] as int,
      audioUrl: map['audioUrl'],
      qualityId: (map['qualityId'] as num?)?.toInt(),
      publishTime: (map['publishTime'] as num?)?.toInt(),
      description: map['description'] as String?,
      playCount: (map['playCount'] as num?)?.toInt(),
      danmakuCount: (map['danmakuCount'] as num?)?.toInt(),
      likeCount: (map['likeCount'] as num?)?.toInt(),
      coinCount: (map['coinCount'] as num?)?.toInt(),
      favoriteCount: (map['favoriteCount'] as num?)?.toInt(),
      shareCount: (map['shareCount'] as num?)?.toInt(),
      replyCount: (map['replyCount'] as num?)?.toInt(),
    );
  }

  Track copyWith({
    String? title,
    String? rawTitle,
    String? uploader,
    String? coverUrl,
    String? musicSource,
    String? musicId,
    int? duration,
    String? audioUrl,
    int? qualityId,
    String? originalUploader,
    int? publishTime,
    String? description,
    int? playCount,
    int? danmakuCount,
    int? likeCount,
    int? coinCount,
    int? favoriteCount,
    int? shareCount,
    int? replyCount,
  }) {
    return Track(
      id: id,
      bvid: bvid,
      cid: cid,
      title: title ?? this.title,
      rawTitle: rawTitle ?? this.rawTitle,
      originalUploader: originalUploader ?? this.originalUploader,
      uploader: uploader ?? this.uploader,
      coverUrl: coverUrl ?? this.coverUrl,
      musicSource: musicSource ?? this.musicSource,
      musicId: musicId ?? this.musicId,
      duration: duration ?? this.duration,
      audioUrl: audioUrl ?? this.audioUrl,
      qualityId: qualityId ?? this.qualityId,
      publishTime: publishTime ?? this.publishTime,
      description: description ?? this.description,
      playCount: playCount ?? this.playCount,
      danmakuCount: danmakuCount ?? this.danmakuCount,
      likeCount: likeCount ?? this.likeCount,
      coinCount: coinCount ?? this.coinCount,
      favoriteCount: favoriteCount ?? this.favoriteCount,
      shareCount: shareCount ?? this.shareCount,
      replyCount: replyCount ?? this.replyCount,
    );
  }

  /// Identity is the track id. Two `Track` objects for the same part — one
  /// from search, one rehydrated from disk — must compare equal so list
  /// lookups behave.
  @override
  bool operator ==(Object other) => other is Track && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Track($id, $title)';
}

/// A holder for "the track the UI is showing" that notifies on *every*
/// assignment of a different object.
///
/// A plain `ValueNotifier<Track?>` cannot be used here. [Track] compares by id
/// (deliberately — see above), so assigning an edited copy of the same track is
/// an assignment of an *equal* value, and `ValueNotifier` silently swallows it.
/// That is exactly what happens after a metadata edit: the docked player kept
/// rendering the pre-edit title, artist and cover until the track changed.
class TrackNotifier extends ChangeNotifier implements ValueListenable<Track?> {
  TrackNotifier([this._value]);

  Track? _value;

  @override
  Track? get value => _value;

  set value(Track? newValue) {
    if (identical(_value, newValue)) return;
    _value = newValue;
    notifyListeners();
  }
}

/// Callback for "play this track", optionally within a specific queue
/// context (e.g. a playlist/favorites). When [queue] is null, the caller's
/// default library (all downloaded tracks) is used.
typedef TrackAction = void Function(Track track, {List<Track>? queue});
