/// Selects the last line whose timestamp has been reached, or -1 before the
/// first line. Both in-app highlighting and system metadata use this timeline.
/// Lines must be sorted by time; a positive offset advances the lyrics.
int findActiveLyricIndex(
  List<LyricLine> lines,
  Duration position, {
  double offsetSeconds = 0,
}) {
  final seconds = position.inMilliseconds / 1000.0 + offsetSeconds;
  var lo = 0;
  var hi = lines.length - 1;
  var index = -1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    if (lines[mid].time <= seconds) {
      index = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  return index;
}

/// A provider-supplied syllable or word. Times are absolute milliseconds.
class LyricWord {
  const LyricWord({required this.text, required this.startMs, required this.endMs});

  final String text;
  final int startMs;
  final int endMs;

  double progress(int positionMs) => endMs <= startMs
      ? (positionMs >= startMs ? 1 : 0)
      : ((positionMs - startMs) / (endMs - startMs)).clamp(0.0, 1.0);

  Map<String, dynamic> toMap() => {'text': text, 'startMs': startMs, 'endMs': endMs};

  factory LyricWord.fromMap(Map<String, dynamic> map) => LyricWord(
    text: map['text'] as String,
    startMs: (map['startMs'] as num).toInt(),
    endMs: (map['endMs'] as num).toInt(),
  );
}

class LyricLine {
  final double time; // in seconds
  final String text;
  final String? translation;
  final int? endMs;
  final List<LyricWord> words;

  LyricLine({
    required this.time,
    required this.text,
    this.translation,
    this.endMs,
    this.words = const [],
  });

  LyricLine withTranslation(String? value) => LyricLine(
    time: time, text: text, translation: value, endMs: endMs, words: words,
  );

  Map<String, dynamic> toMap() {
    return {
      'time': time,
      'text': text,
      'translation': translation,
      if (endMs != null) 'endMs': endMs,
      if (words.isNotEmpty) 'words': words.map((word) => word.toMap()).toList(),
    };
  }

  factory LyricLine.fromMap(Map<String, dynamic> map) {
    return LyricLine(
      time: (map['time'] as num).toDouble(),
      text: map['text'] as String,
      translation: map['translation'] as String?,
      endMs: (map['endMs'] as num?)?.toInt(),
      words: (map['words'] as List? ?? const []).map((word) =>
        LyricWord.fromMap(Map<String, dynamic>.from(word as Map))).toList(),
    );
  }
}

enum LyricProvider {
  netease('netease', '网易云音乐'),
  kugou('kugou', '酷狗音乐'),
  tencent('tencent', 'QQ音乐');

  const LyricProvider(this.apiName, this.label);

  final String apiName;
  final String label;
}

class LyricSearchCandidate {
  const LyricSearchCandidate({
    required this.id,
    required this.title,
    required this.artist,
    required this.provider,
    this.pictureUrl,
    this.songId,
    this.albumName,
    this.durationSeconds,
  });

  final String id;
  final String title;
  final String artist;
  final LyricProvider provider;
  final String? pictureUrl;
  // QQ's lyric service requires these catalog fields, not just songmid.
  final int? songId;
  final String? albumName;
  final int? durationSeconds;

  LyricsReference get reference => LyricsReference(
        provider: provider,
        id: id,
        title: title,
        artist: artist,
        pictureUrl: pictureUrl,
      );
}

class LyricsReference {
  const LyricsReference({
    required this.provider,
    required this.id,
    this.title,
    this.artist,
    this.pictureUrl,
  });

  final LyricProvider provider;
  final String id;
  final String? title;
  final String? artist;
  final String? pictureUrl;

  Map<String, dynamic> toMap() => {
        'provider': provider.apiName,
        'id': id,
        if (title != null) 'title': title,
        if (artist != null) 'artist': artist,
        if (pictureUrl != null) 'pictureUrl': pictureUrl,
      };

  factory LyricsReference.fromMap(Map<String, dynamic> map) {
    final id = map['id'] as String;
    if (id.isEmpty) throw const FormatException('歌曲 ID 不能为空');
    final provider = LyricProvider.values.firstWhere(
      (item) => item.apiName == map['provider'],
    );
    return LyricsReference(
      provider: provider,
      id: id,
      title: map['title'] as String?,
      artist: map['artist'] as String?,
      pictureUrl: map['pictureUrl'] as String?,
    );
  }
}

class LyricsResult {
  // v3 retries the LRC fallbacks saved before the EAPI session / QRC key fix.
  static const currentCacheVersion = 1;
  final String source; // provider api name | 'none'
  final String? songTitle;
  final String? artistName;
  final List<LyricLine> lines;
  final LyricsReference? reference;
  final int cacheVersion;

  bool get needsWordLyricsUpgrade =>
      cacheVersion < currentCacheVersion &&
      !lines.any((line) => line.words.isNotEmpty) &&
      (cacheVersion < 2 || source != LyricProvider.kugou.apiName);

  const LyricsResult({
    required this.source,
    this.songTitle,
    this.artistName,
    required this.lines,
    this.reference,
    this.cacheVersion = currentCacheVersion,
  });

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'cacheVersion': cacheVersion,
      'songTitle': songTitle,
      'artistName': artistName,
      'lines': lines.map((l) => l.toMap()).toList(),
      if (reference != null) 'reference': reference!.toMap(),
    };
  }

  factory LyricsResult.fromMap(Map<String, dynamic> map) {
    final source = map['source'] as String;
    if (source != 'none' &&
        !LyricProvider.values.any((provider) => provider.apiName == source)) {
      throw FormatException('未知歌词来源: $source');
    }
    final rawLines = map['lines'] as List;
    return LyricsResult(
      source: source,
      cacheVersion: (map['cacheVersion'] as num?)?.toInt() ?? 1,
      songTitle: map['songTitle'] as String?,
      artistName: map['artistName'] as String?,
      reference: map['reference'] is Map
          ? LyricsReference.fromMap(Map<String, dynamic>.from(map['reference'] as Map))
          : null,
      lines: rawLines
          .map((l) => LyricLine.fromMap(Map<String, dynamic>.from(l as Map)))
          .toList(),
    );
  }
}
