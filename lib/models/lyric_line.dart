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
      text: map['text'] as String,
      translation: map['translation'] as String?,
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
  final String source; // provider api name | 'none'
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
    final source = map['source'] as String;
    if (source != 'none' &&
        !LyricProvider.values.any((provider) => provider.apiName == source)) {
      throw FormatException('未知歌词来源: $source');
    }
    final rawLines = map['lines'] as List;
    return LyricsResult(
      source: source,
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
