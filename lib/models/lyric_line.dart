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

class LyricsResult {
  final String source; // 'netease' | 'user' | 'current' | 'none'
  final String? songTitle;
  final String? artistName;
  final List<LyricLine> lines;

  const LyricsResult({
    required this.source,
    this.songTitle,
    this.artistName,
    required this.lines,
  });

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'songTitle': songTitle,
      'artistName': artistName,
      'lines': lines.map((l) => l.toMap()).toList(),
    };
  }

  factory LyricsResult.fromMap(Map<String, dynamic> map) {
    final rawLines = map['lines'] as List? ?? const [];
    return LyricsResult(
      source: map['source'] as String? ?? 'none',
      songTitle: map['songTitle'] as String?,
      artistName: map['artistName'] as String?,
      lines: rawLines
          .map((l) => LyricLine.fromMap(Map<String, dynamic>.from(l as Map)))
          .toList(),
    );
  }
}
