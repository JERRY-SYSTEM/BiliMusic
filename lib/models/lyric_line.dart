class LyricLine {
  final double time; // in seconds
  final String text;
  final String? translation;

  LyricLine({
    required this.time,
    required this.text,
    this.translation,
  });

  Map<String, dynamic> toMap() {
    return {
      'time': time,
      'text': text,
      'translation': translation,
    };
  }

  factory LyricLine.fromMap(Map<String, dynamic> map) {
    return LyricLine(
      time: (map['time'] as num).toDouble(),
      text: map['text'] ?? '',
      translation: map['translation'],
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
  });

  final String id;
  final String title;
  final String artist;
  final LyricProvider provider;
  final String? pictureUrl;
}

class LyricsResult {
  final String source; // provider api name | 'user' | 'current' | 'none'
  final String? songTitle;
  final String? artistName;
  final List<LyricLine> lines;
  final bool isManual;

  const LyricsResult({
    required this.source,
    this.songTitle,
    this.artistName,
    required this.lines,
    this.isManual = false,
  });

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'songTitle': songTitle,
      'artistName': artistName,
      'lines': lines.map((l) => l.toMap()).toList(),
      'isManual': isManual,
    };
  }

  factory LyricsResult.fromMap(Map<String, dynamic> map) {
    final rawLines = map['lines'] as List? ?? const [];
    return LyricsResult(
      source: map['source'] as String? ?? 'none',
      songTitle: map['songTitle'] as String?,
      artistName: map['artistName'] as String?,
      isManual: map['isManual'] as bool? ?? false,
      lines: rawLines
          .map((l) => LyricLine.fromMap(Map<String, dynamic>.from(l as Map)))
          .toList(),
    );
  }
}
