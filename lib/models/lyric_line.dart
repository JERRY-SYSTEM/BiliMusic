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
    final provider = LyricProvider.values.firstWhere(
      (item) => item.apiName == map['provider'],
      orElse: () => LyricProvider.netease,
    );
    return LyricsReference(
      provider: provider,
      id: map['id'] as String,
      title: map['title'] as String?,
      artist: map['artist'] as String?,
      pictureUrl: map['pictureUrl'] as String?,
    );
  }
}

class LyricsResult {
  final String source; // provider api name | 'user' | 'current' | 'none'
  final String? songTitle;
  final String? artistName;
  final List<LyricLine> lines;
  final LyricsReference? reference;

  const LyricsResult({
    required this.source,
    this.songTitle,
    this.artistName,
    required this.lines,
    this.reference,
  });

  Map<String, dynamic> toMap() {
    return {
      'source': source,
      'songTitle': songTitle,
      'artistName': artistName,
      'lines': lines.map((l) => l.toMap()).toList(),
      if (reference != null) 'reference': reference!.toMap(),
    };
  }

  factory LyricsResult.fromMap(Map<String, dynamic> map) {
    final rawLines = map['lines'] as List? ?? const [];
    return LyricsResult(
      source: map['source'] as String? ?? 'none',
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
