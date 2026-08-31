import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import '../models/lyric_line.dart';
import 'bili_http.dart';

class _ArtistResolution {
  const _ArtistResolution(this.artist, this.bonus);
  final String? artist;

  /// Score bonus: 2 for a DB-confirmed query hit, 1 for an
  /// artist-existence-only hit (weaker signal).
  final int bonus;
}

class LyricsEngine {
  static final HttpClient _client = biliHttpClient();
  static final Map<String, Future<String?>> _neteasePictureCache = {};

  static String? _normalizePictureUrl(Object? value) {
    final raw = value?.toString().trim() ?? '';
    if (raw.isEmpty) return null;
    if (raw.startsWith('//')) return 'https:$raw';
    return raw.replaceFirst('http:', 'https:');
  }

  static Future<String?> _fetchNetEasePictureUrl(String id) {
    return _neteasePictureCache.putIfAbsent(id, () async {
      final body = await _httpGet(
        'https://music.163.com/api/song/detail?ids=%5B${Uri.encodeComponent(id)}%5D',
        headers: const {'Referer': 'https://music.163.com'},
      );
      if (body == null) return null;
      final songs = jsonDecode(body)['songs'] as List? ?? const [];
      if (songs.isEmpty || songs.first is! Map) return null;
      final album = (songs.first as Map)['album'];
      return _normalizePictureUrl(album is Map ? album['picUrl'] : null);
    });
  }

  static Future<String?> _httpGet(String urlStr, {Map<String, String>? headers}) async {
    try {
      final req = await _client.getUrl(Uri.parse(urlStr));
      headers?.forEach((k, v) => req.headers.set(k, v));
      final res = await req.close();
      if (res.statusCode == 200) {
        return await res.transform(utf8.decoder).join();
      }
      // Drain non-200 bodies so the connection returns to the pool; with
      // maxConnectionsPerHost = 4, a few un-drained 4xx/5xx responses would
      // exhaust it and later requests would queue behind idleTimeout.
      await res.drain<void>();
    } catch (e) {
      debugPrint('Lyrics HTTP error: $e');
    }
    return null;
  }

  static Future<List<LyricSearchCandidate>> searchCandidates(
    String keyword, {
    LyricProvider provider = LyricProvider.netease,
  }) async {
    final query = keyword.trim();
    if (query.isEmpty) return const [];
    try {
      switch (provider) {
        case LyricProvider.netease:
          final body = await _httpGet(
            'https://music.163.com/api/search/get?s=${Uri.encodeComponent(query)}&type=1&limit=10',
            headers: const {'Referer': 'https://music.163.com'},
          );
          final songs = body == null
              ? const []
              : (jsonDecode(body)['result']?['songs'] as List? ?? const []);
          final candidates = await Future.wait(songs.whereType<Map>().map((song) async {
            final id = song['id']?.toString() ?? '';
            final artists = (song['artists'] as List? ?? const [])
                .whereType<Map>()
                .map((artist) => artist['name']?.toString() ?? '')
                .where((name) => name.isNotEmpty)
                .join(' / ');
            final album = song['album'];
            var pictureUrl = _normalizePictureUrl(album is Map
                ? (album['picUrl'] ?? album['blurPicUrl'])
                : null);
            pictureUrl ??= id.isEmpty ? null : await _fetchNetEasePictureUrl(id);
            return LyricSearchCandidate(
              id: id,
              title: song['name']?.toString() ?? '',
              artist: artists,
              provider: provider,
              pictureUrl: pictureUrl,
            );
          }));
          return candidates
              .where((item) => item.id.isNotEmpty)
              .toList(growable: false);
        case LyricProvider.kugou:
          final body = await _httpGet(
            'https://songsearch.kugou.com/song_search_v2?keyword=${Uri.encodeComponent(query)}&page=1&pagesize=10&platform=WebFilter',
          );
          final songs = body == null
              ? const []
              : (jsonDecode(body)['data']?['lists'] as List? ?? const []);
          return songs.whereType<Map>().map((song) => LyricSearchCandidate(
                id: (song['FileHash'] ?? song['EMixSongID'] ?? '').toString(),
                title: (song['SongName'] ?? '').toString(),
                artist: (song['SingerName'] ?? '').toString(),
                provider: provider,
                pictureUrl: (song['Image'] ?? '')
                    .toString()
                    .replaceAll('{size}', '120'),
              )).where((item) => item.id.isNotEmpty).toList(growable: false);
        case LyricProvider.tencent:
          final body = await _httpGet(
            'https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=${Uri.encodeComponent(query)}&p=1&n=10&format=json',
            headers: const {'Referer': 'https://y.qq.com/'},
          );
          final songs = body == null
              ? const []
              : (jsonDecode(body)['data']?['song']?['list'] as List? ?? const []);
          return songs.whereType<Map>().map((song) {
            final artists = (song['singer'] as List? ?? const [])
                .whereType<Map>()
                .map((artist) => artist['name']?.toString() ?? '')
                .where((name) => name.isNotEmpty)
                .join(' / ');
            return LyricSearchCandidate(
              id: (song['songmid'] ?? '').toString(),
              title: (song['songname'] ?? '').toString(),
              artist: artists,
              provider: provider,
              pictureUrl: (song['albummid'] ?? '').toString().isEmpty
                  ? null
                  : 'https://y.gtimg.cn/music/photo_new/T002R120x120M000${song['albummid']}.jpg',
            );
          }).where((item) => item.id.isNotEmpty).toList(growable: false);
      }
    } catch (error) {
      debugPrint('${provider.label} lyric search error: $error');
      rethrow;
    }
  }

  static Future<LyricsResult?> fetchCandidateLyrics(
    LyricSearchCandidate candidate,
  ) async {
    try {
      switch (candidate.provider) {
        case LyricProvider.netease:
          final body = await _httpGet(
            'https://music.163.com/api/song/lyric?id=${Uri.encodeComponent(candidate.id)}&lv=-1&tv=-1',
            headers: const {'Referer': 'https://music.163.com'},
          );
          if (body == null) return null;
          final json = jsonDecode(body);
          return _resultFromRawLyrics(
            candidate,
            (json['lrc']?['lyric'] ?? '').toString(),
            (json['tlyric']?['lyric'] ?? '').toString(),
          );
        case LyricProvider.kugou:
          final searchBody = await _httpGet(
            'https://lyrics.kugou.com/search?ver=1&man=yes&client=pc&hash=${Uri.encodeComponent(candidate.id)}',
          );
          if (searchBody == null) return null;
          final entries = jsonDecode(searchBody)['candidates'] as List? ?? const [];
          if (entries.isEmpty || entries.first is! Map) return null;
          final entry = entries.first as Map;
          final id = entry['id']?.toString() ?? '';
          final accessKey = entry['accesskey']?.toString() ?? '';
          if (id.isEmpty || accessKey.isEmpty) return null;
          final downloadBody = await _httpGet(
            'https://lyrics.kugou.com/download?ver=1&client=pc&id=${Uri.encodeComponent(id)}&accesskey=${Uri.encodeComponent(accessKey)}&fmt=lrc&charset=utf8',
          );
          if (downloadBody == null) return null;
          final content = jsonDecode(downloadBody)['content']?.toString() ?? '';
          if (content.isEmpty) return null;
          return _resultFromRawLyrics(
            candidate,
            utf8.decode(base64Decode(content)),
            '',
          );
        case LyricProvider.tencent:
          final body = await _httpGet(
            'https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=${Uri.encodeComponent(candidate.id)}&format=json&nobase64=1',
            headers: const {'Referer': 'https://y.qq.com/'},
          );
          if (body == null) return null;
          final json = jsonDecode(body);
          return _resultFromRawLyrics(
            candidate,
            _decodeTencentText((json['lyric'] ?? '').toString()),
            _decodeTencentText((json['trans'] ?? '').toString()),
          );
      }
    } catch (error) {
      debugPrint('${candidate.provider.label} lyric fetch error: $error');
      return null;
    }
  }

  static LyricsResult? _resultFromRawLyrics(
    LyricSearchCandidate candidate,
    String rawLyrics,
    String rawTranslation,
  ) {
    final lines = parseLrc(rawLyrics);
    if (lines.isEmpty) return null;
    final translations = parseLrc(rawTranslation);
    if (translations.isNotEmpty) {
      var translationIndex = 0;
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        while (translationIndex < translations.length &&
            translations[translationIndex].time < line.time - 0.5) {
          translationIndex++;
        }
        if (translationIndex < translations.length &&
            (translations[translationIndex].time - line.time).abs() < 0.5) {
          lines[index] = LyricLine(
            time: line.time,
            text: line.text,
            translation: translations[translationIndex].text,
          );
        }
      }
    }
    return LyricsResult(
      source: candidate.provider.apiName,
      songTitle: candidate.title,
      artistName: candidate.artist,
      lines: lines,
      isManual: true,
    );
  }

  static String _decodeTencentText(String value) => value
      .replaceAllMapped(
        RegExp(r'&#(\d+);'),
        (match) => String.fromCharCode(int.tryParse(match.group(1)!) ?? 0),
      )
      .replaceAll('&apos;', "'")
      .replaceAll('&quot;', '"')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&amp;', '&');

  // Common noise words in B站 titles
  static final RegExp noiseKeywords = RegExp(
    r'(?:4K|1080P|720P|60帧|50帧|杜比视界|杜比全景声|杜比音效|Hi-?Res|无损音质|无损|高音质|高音質|HQ|SQ|'
    r'官方MV|\bMV\b|纯享版|纯享|纯净版|动态歌词|LRC|歌词排版|流行歌曲|全场|完整版|片段|精剪|多机位|直拍|现场|\bLive\b|'
    r'首唱|单曲循环|单曲|纯音频|Audio|字幕组|字幕|重置|超清|高清|录音棚|在.*大声听|'
    r'主题曲|片尾曲|片头曲|插曲|推广曲|印象曲|角色曲|宣传曲|ED|OP|OST|'
    r'舞台|带来|第\s*\d+\s*[季期届集]|EP\d+)',
    caseSensitive: false,
  );

  // Noise words that can be *embedded* in a real name token ("周深翻唱",
  // "陈奕迅新歌", "毛不易演唱会"). Dropping such a token whole loses the
  // name; stripping these out of the token keeps it. Deliberately disjoint
  // from [noiseKeywords]'s format class: format words (无损, 音质, 4K…) leave
  // meaningless residue and must still kill the whole token. The ASCII glue
  // words are word-anchored so they cannot eat real words out of a token
  // (Alive, Discovery, Deliver must survive).
  static final RegExp glueNoise = RegExp(
    r'(?:翻唱|原唱|演唱|新歌|混音|修音|字幕|伴奏|现场|演唱会|纯享|单曲|直拍|修复|'
    r'完整版|官方版|版本|首唱|歌词排版|歌词|舞台|合作|UP主|\bCover\b|\bMV\b|\bLive\b)',
    caseSensitive: false,
  );

  /// A token that is nothing but a separator ("-", "–", "—", "|"…). Such
  /// tokens must survive [_noisyClean]: step-4's "Artist - Song" split runs on
  /// the cleaned title and needs the dash, a 1-char token otherwise dropped.
  static final RegExp pureSeparatorToken = RegExp(r'^[-–—/︱|丨_]+$');

  // Follows a 《…》 pair to flag it as a show name rather than the song:
  // season markers ("第二季", "EP09") and show-suffix tags ("主题曲" etc.).
  static final RegExp showMarker = RegExp(
    r'第\s*\d+[季期届集]|EP\d+|\d+\s*季|'
    r'主题曲|片尾曲|片头曲|插曲|推广曲|印象曲|角色曲|宣传曲|ED|OP|OST',
    caseSensitive: false,
  );

  // Token-level noise: if a space-separated token contains any of these, the
  // whole token is noise (spaces are the atomic unit of titles).
  static final RegExp tokenNoise = RegExp(
    noiseKeywords.pattern + r'|(?:\bCover\b|翻唱|原唱|词/曲|混音|演唱|UP主|版本)',
    caseSensitive: false,
  );

  static final RegExp bracketCategory = RegExp(
    r'合集|歌单|珍藏|榜|反应|点评|解析|试听',
    caseSensitive: false,
  );

  // Shared structural regexes: cleaning and candidate generation must strip
  // exactly the same brackets, or the two paths disagree on the same title.
  static final RegExp htmlTag = RegExp(r'<[^>]+>');
  static final RegExp bracketContent = RegExp(r'[【\[]([^】\]]+)[】\]]');
  static final RegExp bookBracket = RegExp(r'《([^》]+)》');
  static final RegExp bracketStripper =
      RegExp(r'【[^】]+】|\[[^\]]+\]|（[^）]+）|\([^)]+\)|《[^》]+》');
  static final RegExp parenSubtitle = RegExp(r'\s*[\(（][^\)）]+[\)）]');
  static final RegExp separator =
      RegExp(r'^(.+?)\s*[-–—/︱|丨_]\s*(\S.*)$');

  static String _preprocess(String raw) {
    return raw
        .trim()
        .replaceAll(htmlTag, '')
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  /// Drops brackets, parens and noise from [s], preserving the surviving
  /// space-separated tokens.
  ///
  /// Two classes of noise, handled differently:
  ///  * [glueNoise] words (翻唱, 新歌, Cover…) are stripped *out of* a token,
  ///    so "周深翻唱" keeps 周深 instead of vanishing — dropping the whole
  ///    token used to lose the name whenever a verb was glued to it.
  ///  * [tokenNoise] (format words like 无损, plus glue words in their own
  ///    right) kills the whole token, because their residue is meaningless.
  ///    Bar-like separators (|｜、,，/) also split tokens, so "Song｜完整版｜
  ///    歌词LyricsVideo" keeps the song part instead of dying with the noise.
  static String _noisyClean(String s) {
    final out = <String>[];
    for (final t in s.replaceAll(bracketStripper, ' ').split(RegExp(r'\s+'))) {
      if (t.isEmpty) continue;
      // A whole-token separator ("/", "|", "｜") must survive for step-4's
      // "Artist - Song" split — the bar-split below would otherwise destroy
      // it (and the pureSeparatorToken check would only see its empty husks).
      if (pureSeparatorToken.hasMatch(t)) {
        out.add(t);
        continue;
      }
      for (final seg in t.split(RegExp(r'[|｜、,，/]'))) {
        if (pureSeparatorToken.hasMatch(seg)) {
          out.add(seg);
          continue;
        }
        for (final sub in seg.replaceAll(glueNoise, ' ').split(RegExp(r'\s+'))) {
          if (sub.isEmpty || sub.length < 2) continue;
          if (tokenNoise.hasMatch(sub)) continue;
          out.add(sub);
        }
      }
    }
    return out.join(' ');
  }

  // Title cleaner to extract clean song name & artist from Bilibili video titles
  //
  // Deliberately structural: brackets supply the artist, 《》 supplies the
  // song, separators split "Artist - Song", and space-separated tokens are the
  // unit of noise removal. All semantic disambiguation (which 《》 is the song,
  // who the singer is, collaboration brackets like 【A&B 歌名】) is delegated to
  // [cleanTitleWithValidation]'s lyric-DB search; this method is only the
  // offline fallback and the instant first pass.
  static Map<String, String> cleanTitle(String rawTitle, {String defaultArtist = ''}) {
    final title = _preprocess(rawTitle);
    var artist = defaultArtist.trim();
    if (artist == '未知UP主' || artist == '未知歌手' || artist == 'UP主') {
      artist = '';
    }

    String? song;

    // 2. Artist from brackets like 【周深】, [周深], or space-split
    //    【Artist1&Artist2 SongTitle】 patterns.
    final bracketMatch = bracketContent.firstMatch(title);
    if (bracketMatch != null) {
      final content = bracketMatch.group(1)!.trim();
      if (!bracketCategory.hasMatch(content)) {
        // Vertical bars are category separators (【周深｜舞台】), not part of
        // the name — unlike &, which joins real collab artists.
        final tokens =
            content.split(RegExp(r'[\s|｜]+')).where((t) => t.isNotEmpty).toList();
        final nonNoise = tokens.where((t) => !tokenNoise.hasMatch(t)).toList();
        // A bracket whose every token is noise (【现场】, 【Live】) carries no
        // info; one mixing a name and a category keeps the name.
        if (tokens.isNotEmpty && nonNoise.isNotEmpty) {
          if (nonNoise.length >= 2) {
            artist = nonNoise.sublist(0, nonNoise.length - 1).join(' ');
            song = nonNoise.last;
          } else {
            artist = nonNoise.join(' ');
          }
        }
      }
    }

    // 3. Song from the 《...》 brackets. Titles often carry a show name next
    //    to the real song, so a pair followed by a season marker or show-suffix
    //    tag ("《音乐缘计划》第二季EP09…", "《衣裳中国》主题曲") is the *show*;
    //    the song is a surviving unmarked pair. With no markers at all the LAST
    //    pair wins (《show》…《song》), and a single pair is the song outright.
    final pairs = bookBracket.allMatches(title).toList();
    if (pairs.isNotEmpty) {
      Match? songPair;
      final unmarked = pairs.where((m) {
        final tail = title.substring(m.end);
        final peek = tail.length > 10 ? tail.substring(0, 10) : tail;
        return !showMarker.hasMatch(peek);
      }).toList();
      songPair = unmarked.isNotEmpty ? unmarked.last : pairs.last;
      song = songPair.group(1)!.trim();
      // A plain-text artist sitting between the last leading 【】/[] bracket
      // and the song bracket beats the bracket content — but only under the
      // two shapes where that is reliably true, because on B站 the bracket is
      // USUALLY the artist ("【周深】《画绢》") and the text between bracket
      // and song is usually junk (dates, 合集 tags, verb phrases):
      //   1. the between text is a collab list ("【声生不息3】 黄绮珊&周深
      //      《岁月》" — &/、 only ever join artists);
      //   2. the bracket is a show-season tag (CJK name ending in a 1–2 digit
      //      season: 声生不息3, 我们的歌5 — not SNH48-style ASCII ids) and the
      //      between text is a single bare name.
      final leadingBrackets = bracketContent
          .allMatches(title.substring(0, songPair.start))
          .toList();
      if (leadingBrackets.isNotEmpty) {
        final between = _noisyClean(
            title.substring(leadingBrackets.last.end, songPair.start));
        final betweenTokens = between
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList();
        if (betweenTokens.isNotEmpty) {
          final bracketText = leadingBrackets.last.group(1)!.trim();
          final collabToken = betweenTokens
              .where((t) => RegExp(r'[&、,，]').hasMatch(t))
              .toList();
          if (collabToken.isNotEmpty) {
            artist = collabToken.first;
          } else if (betweenTokens.length >= 2 &&
              betweenTokens.every((t) =>
                  _looksLikeBareName(t) && !_betweenJunk.contains(t))) {
            // "【声生不息】陈楚生 周深 合作舞台《逆光》": several bare names
            // between a tag bracket and the song bracket are collaborating
            // artists — space-separated collabs carry no & marker. Noise
            // tokens (舞台, 主题曲…) are already filtered by _noisyClean, and
            // the every() gate keeps dates/cities/junk out (verified against
            // the 540-title corpus with zero unintended changes). Exact
            // matches only: substring noise filtering would eat tokens glued
            // to a real name ("陈奕迅新歌" must not drop 陈奕迅).
            artist = betweenTokens.join(' ');
          } else if (_looksLikeShowSeason(bracketText) &&
              betweenTokens.length == 1 &&
              _looksLikeBareName(betweenTokens.first)) {
            artist = betweenTokens.first;
          }
        }
      }
      if (artist.isEmpty || artist == defaultArtist) {
        final beforeTokens = _noisyClean(title.substring(0, songPair.start))
            .split(RegExp(r'\s+'))
            .where((t) => t.isNotEmpty)
            .toList();
        // The token nearest the 《》 is most likely the artist's name; when
        // several precede it ("周深 古风《大鱼》") the leading one wins.
        if (beforeTokens.isNotEmpty) {
          artist = beforeTokens.first;
        }
      }
      if (artist.isEmpty || artist == defaultArtist) {
        final after = _noisyClean(title.substring(songPair.end));
        final leading = RegExp(r'^([\u4e00-\u9fa5A-Za-z0-9_·•.]{2,12})').firstMatch(after);
        if (leading != null && !tokenNoise.hasMatch(leading.group(1)!)) {
          artist = leading.group(1)!;
        }
      }
    }

    // 4. No book brackets: split "Artist - SongTitle" on the cleaned title.
    if (song == null) {
      final clean = _noisyClean(title);
      final parts = clean.split(RegExp(r'\s+[-–—/︱|丨_]\s+'));
      if (parts.length >= 2 && parts[0].isNotEmpty && parts[1].isNotEmpty) {
        if (artist.isEmpty || artist == defaultArtist) artist = parts[0];
        song = parts[1];
      } else {
        final dash = RegExp(r'^([\u4e00-\u9fa5A-Za-z0-9·•.]{2,10})\s*[-–—]\s*(.+)$')
            .firstMatch(clean);
        if (dash != null) {
          if (artist.isEmpty || artist == defaultArtist) artist = dash.group(1)!;
          song = dash.group(2)!;
        }
      }
      song ??= clean;
    }

    final finalSong = song.trim();
    return {
      'songTitle': finalSong.isEmpty ? rawTitle : finalSong,
      'artist': artist.isNotEmpty ? artist : defaultArtist,
    };
  }

  /// Structural candidate extraction for DB-backed validation: every 《…》
  /// content, every 【…】 content (whole and space-split), the part after an
  /// "Artist - Song" separator, and every surviving space-separated token.
  static List<Map<String, String>> _generateCandidates(String rawTitle) {
    final title = _preprocess(rawTitle);
    final candidates = <Map<String, String>>[];

    void add(String song, [String artistHint = '', int bookIdx = -1, bool showLike = false]) {
      final s = song.trim();
      final hint = artistHint.trim();
      final norm = _normalize(s);
      if (s.isEmpty || norm.isEmpty || norm.length > 24) return;
      if (tokenNoise.hasMatch(s)) return;
      if (candidates.any((c) => _normalize(c['song']!) == norm)) return;
      candidates.add({
        'song': s,
        'artistHint': hint,
        if (bookIdx >= 0) 'bookIdx': '$bookIdx',
        if (showLike) 'showLike': '1',
      });
    }

    var bookIdx = 0;
    for (final m in bookBracket.allMatches(title)) {
      final tail = title.substring(m.end);
      final peek = tail.length > 10 ? tail.substring(0, 10) : tail;
      add(m.group(1)!, '', bookIdx++, showMarker.hasMatch(peek));
    }
    for (final m in bracketContent.allMatches(title)) {
      final content = m.group(1)!.trim();
      if (content.isEmpty) continue;
      add(content);
      final tokens =
          content.split(RegExp(r'[\s|｜]+')).where((t) => t.isNotEmpty).toList();
      if (tokens.length >= 2) {
        add(tokens.last, tokens.sublist(0, tokens.length - 1).join(' '));
      }
    }
    final sep = separator.firstMatch(title);
    if (sep != null) {
      // Drop show/channel metadata after the first bar: "…经典 | 音乐缘计划
      // | Melody Journey | iQIYI奇艺音悦台" — only the pre-bar part is a song.
      final songPart = sep.group(2)!.split(RegExp(r'[|｜丨]')).first.trim();
      if (songPart.isNotEmpty) add(songPart, sep.group(1)!);
      // B站 cover titles are often "Song - Artist" ("遥遥-周深", "不舍-周深")
      // instead of "Artist - Song", and the rule pass cannot know which. When
      // both sides are short bare names, also emit the reversed pairing and
      // let the DB-backed validation disambiguate.
      final g1 = _noisyClean(sep.group(1)!).trim();
      final g2 = _noisyClean(songPart).trim();
      if (_looksLikeBareName(g1) &&
          _looksLikeBareName(g2) &&
          _normalize(g1) != _normalize(g2)) {
        add(g1, g2);
      }
    }
    final bare = title.replaceAll(bracketStripper, ' ');
    // Bare tokens after the first bar separator are show names / uploader
    // channels, never song parts (" | 音乐缘计划 | Melody Journey | iQIYI…").
    final bareHead = bare.split(RegExp(r'[|｜丨]')).first;
    for (final t in bareHead.split(RegExp(r'\s+'))) {
      add(t);
    }
    return candidates.length > 8 ? candidates.sublist(0, 8) : candidates;
  }

  /// Advanced title & artist extractor using lyric database cross-validation.
  ///
  /// Generates every plausible song candidate structurally (see
  /// [_generateCandidates]), searches each against NetEase, and picks
  /// the candidate whose official metadata best matches the raw video title:
  /// an official song name or artist that appears verbatim in the raw title is
  /// the strongest signal. [cleanTitle]'s rule-based result is only the artist
  /// fallback and the offline result.
  /// In-memory memo of confirmed validation results, keyed by raw title +
  /// default artist. 智能识别 must return the identical result no matter how
  /// many times the user taps it — the lyric DB's answer can vary between
  /// calls, and a repeated tap must not flip the fields back and forth.
  /// Only DB-confirmed results are memoized: a failed lookup stays retryable.
  static final Map<String, Map<String, String>> _validationMemo = {};

  static Future<Map<String, String>> cleanTitleWithValidation(
    String rawTitle, {
    String defaultArtist = '',
  }) async {
    final memoKey = '$rawTitle\x00$defaultArtist';
    final memoized = _validationMemo[memoKey];
    if (memoized != null) return memoized;

    final fallback = cleanTitle(rawTitle, defaultArtist: defaultArtist);
    final normRaw = _normalize(rawTitle);

    final candidates = _generateCandidates(rawTitle);
    // A bare song name like 《逆光》 alone finds the most popular 逆光 (e.g.
    // 孙燕姿's), whose artist is not in the title — validation then kept the
    // rule pass's artist, laundering it. Hinting each book candidate with the
    // rule pass's artist makes fetchFromNetEase try "artist song" first, so
    // the live duet (逆光 (live), 陈楚生/周深) outranks the studio original.
    // fetchFromNetEase still falls back to the bare song query internally.
    final fallbackArtist = (fallback['artist'] ?? '').trim();
    if (fallbackArtist.isNotEmpty && fallbackArtist != defaultArtist) {
      for (final c in candidates) {
        if (c.containsKey('bookIdx') && (c['artistHint'] ?? '').isEmpty) {
          c['artistHint'] = fallbackArtist;
        }
      }
    }
    // When at least one 《…》 pair survives as a plausible song, pairs that
    // are structurally show names (followed by 第二季/EP09/主题曲…) are skipped
    // entirely: searching them wastes a request and lets a wrong-but-matching
    // hit win. If every pair is show-like, they are all still consulted.
    final hasUnmarkedBook = candidates.any(
        (c) => c.containsKey('bookIdx') && c['showLike'] != '1');

    String? bestSong;
    String? bestArtist;
    var bestEffective = -1;

    for (final candidate in candidates) {
      if (candidate['showLike'] == '1' && hasUnmarkedBook) continue;
      final song = candidate['song']!;
      final hint = candidate['artistHint'];
      final artistQuery = (hint != null && hint.isNotEmpty) ? hint : null;
      // Book-bracket order: on a tie the LAST 《…》 wins — the earlier ones
      // are the show. Non-book candidates rank below every book pair.
      final bookIdx = int.tryParse(candidate['bookIdx'] ?? '') ?? -1;

      final result = await fetchFromNetEase(song, artist: artistQuery);
      if (result == null) continue;

      final officialSong = (result.songTitle ?? '').trim();
      final officialArtist = (result.artistName ?? '').trim();
      // Strip provider parentheses subtitles like "心火 (Live)" or " (电影《...》)"
      final cleanOfficialSong = officialSong.replaceAll(parenSubtitle, '').trim();
      final offSongNorm = _normalize(cleanOfficialSong);
      final offArtistNorm = _normalize(officialArtist);
      final candNorm = _normalize(song);

      // An official title that is really the whole episode title (iQIYI 纯享
      // tracks) must never become the song name — or the cross-validation
      // "confirms" the raw video title itself.
      if (!_isSaneOfficialTitle(cleanOfficialSong)) continue;
      if (offSongNorm.isEmpty) continue;

      final songInRaw = normRaw.contains(offSongNorm);
      final songMatchesCandidate = offSongNorm == candNorm ||
          candNorm.contains(offSongNorm) ||
          offSongNorm.contains(candNorm);
      final artistInRaw = offArtistNorm.isNotEmpty && normRaw.contains(offArtistNorm);
      final hasLyrics = result.lines.isNotEmpty;
      // A search-farm upload titled exactly like the whole raw title ("遥遥
      // 周深" for the title 遥遥-周深). Its songInRaw/songMatches bonuses are
      // tautologies (the title contains itself) — award neither, and fall back
      // to the candidate's own song name rather than the echoed DB title.
      final isTitleEcho = offSongNorm.isNotEmpty && offSongNorm == normRaw;

      var score = 0;
      if (hasLyrics) score += 1;
      if (!isTitleEcho) {
        if (songInRaw) score += 2;
        if (songMatchesCandidate) score += 1;
      }
      if (artistInRaw) score += 2;

      // Without the song matching the title (or the candidate), an artist-only
      // search would happily return that artist's arbitrary song.
      if ((songInRaw || songMatchesCandidate) && score > 0) {
        // The DB confirmed the *song* but not the *singer*. Surrendering to
        // the offline fallback here is the classic wrong-artist bug: for a
        // 周深 cover of 《不舍》 the most popular NetEase 不舍 is by someone
        // else, whose name is not in the title — yet 周深 is right there.
        // Resolve the artist from the raw title before giving up.
        var hitArtist = artistInRaw ? officialArtist : null;
        var artistScore = 0;
        if (hitArtist == null) {
          // Resolution costs up to four more HTTP requests per candidate
          // (over a client capped at 4 connections/host), and it only ever
          // adds 1–2 to the score — a candidate that cannot beat the current
          // best even with the maximum bonus can never win, so skip it.
          if ((score + 2) * 10 + bookIdx <= bestEffective) continue;
          final resolved = await _resolveArtistFromTitle(
            song: song,
            hint: artistQuery,
            normRaw: normRaw,
            rawTitle: rawTitle,
          );
          hitArtist = resolved.artist;
          artistScore = resolved.bonus;
          if (hitArtist != null) score += artistScore;
        }

        final effective = score * 10 + bookIdx;
        if (effective > bestEffective) {
          bestEffective = effective;
          bestSong = isTitleEcho
              ? song
              : (cleanOfficialSong.isNotEmpty ? cleanOfficialSong : officialSong);
          bestArtist = hitArtist ?? fallback['artist']!;
        }
      }
    }

    if (bestSong == null) return fallback;
    final result = {
      'songTitle': bestSong,
      'artist': bestArtist!,
    };
    // Bounded memo: a long session taps many different titles; never let it
    // grow without bound.
    if (_validationMemo.length > 200) _validationMemo.clear();
    _validationMemo[memoKey] = result;
    return result;
  }

  /// Cross-validated artist resolution when the DB confirmed the song but its
  /// official artist is not in the raw title.
  ///
  /// Tries, in order:
  ///  1. the query's artist hint (a plausible name), then each name-like title
  ///     token, as an "artist song" query — accepting the candidate when the
  ///     result's artist is in the title or is the candidate itself
  ///     ("【纯净版】有可能的夜晚 周深 歌手2020" → "周深 有可能的夜晚" finds
  ///     周深's live version; "周深翻唱《不舍》" → hint 周深, no matter that
  ///     the popular 不舍 on NetEase is 岁枝's cover). The hint is *not*
  ///     trusted bare: in a reversed "Song - Artist" title the hint can be the
  ///     song ("周深-世界赠予我的" reversed candidate hints 世界赠予我的), and
  ///     only the DB can tell it apart.
  ///  2. CJK title tokens via a bare artist-existence check ("周深 遥遥" —
  ///     NetEase has no 周深 遥遥, but 周深 exists as an artist). ASCII names
  ///     are too generic to trust on existence alone (Melody, Journey…).
  static Future<_ArtistResolution> _resolveArtistFromTitle({
    required String song,
    required String? hint,
    required String normRaw,
    required String rawTitle,
  }) async {
    final songNorm = _normalize(song);
    final hintNorm = hint == null ? '' : _normalize(hint);
    final tokens = <String>[
      if (hint != null && hint.isNotEmpty && _looksLikeBareName(hint)) hint,
      ..._titleNameTokens(rawTitle).where((t) {
        final n = _normalize(t);
        return n.isNotEmpty && n != songNorm && n != hintNorm;
      }),
    ];

    for (final token in tokens.take(2)) {
      final res = await fetchFromNetEase(song, artist: token);
      if (res == null || res.lines.isEmpty) continue;
      final resArtist = (res.artistName ?? '').trim();
      final resArtistNorm = _normalize(resArtist);
      if (resArtistNorm.isEmpty) continue;
      if (normRaw.contains(resArtistNorm) ||
          resArtistNorm.contains(_normalize(token))) {
        return _ArtistResolution(
            normRaw.contains(resArtistNorm) ? resArtist : token, 2);
      }
    }

    for (final token in tokens.take(2)) {
      if (_isCjkNameLike(token) && await _netEaseArtistExists(token)) {
        return _ArtistResolution(token, 1);
      }
    }
    return const _ArtistResolution(null, 0);
  }

  /// A token that reads like one artist name, CJK only (2–7 name characters).
  static bool _isCjkNameLike(String t) =>
      RegExp(r'^[\u4e00-\u9fa5·]{2,7}$').hasMatch(t);

  /// Name-like (2–7 CJK/ASCII chars) tokens surviving [rawTitle]'s noise
  /// cleanup, in title order. These are the plausible singer names.
  static List<String> _titleNameTokens(String rawTitle) {
    return _noisyClean(rawTitle)
        .split(RegExp(r'\s+'))
        .where((t) => t.isNotEmpty && _looksLikeBareName(t))
        .toList();
  }

  /// Whether [name] is a real NetEase artist (type=100 search), memoized per
  /// session. Used to trust a title token as the singer without a full
  /// "artist song" lyric hit.
  static final Map<String, bool> _artistExistsMemo = {};

  static Future<bool> _netEaseArtistExists(String name) async {
    final key = _normalize(name);
    if (key.isEmpty) return false;
    final cached = _artistExistsMemo[key];
    if (cached != null) return cached;
    final url = 'https://music.163.com/api/search/get'
        '?s=${Uri.encodeComponent(name)}&type=100&limit=5';
    try {
      final body = await _httpGet(url, headers: {'Referer': 'https://music.163.com'});
      if (body != null) {
        final json = jsonDecode(body);
        final artists = json['result']?['artists'] as List? ?? [];
        final exists = artists.any((a) {
          final an = (a is Map ? a['name'] as String? : null) ?? '';
          return an.isNotEmpty && _normalize(an) == key;
        });
        if (_artistExistsMemo.length > 200) _artistExistsMemo.clear();
        _artistExistsMemo[key] = exists;
        return exists;
      }
    } catch (e) {
      debugPrint('NetEase artist check error: $e');
    }
    return false;
  }

  /// Matches a provider song name against a search title. Provider names
  /// compare with their parenthesised subtitle stripped ("岁月 (live)" must
  /// match 《岁月》), and a compound "artist song" title also matches on its
  /// post-space part — otherwise short song names (2–3 chars, e.g. 岁月)
  /// could never pass [isTitleMatching]'s length guard against a query like
  /// "黄绮珊&周深 岁月". A query may carry several artist tokens before the
  /// song ("陈楚生 周深 逆光"), so every space-suffix is tried, not just the
  /// first tail.
  static bool matchesSongQuery(String songName, String title) {
    final cleanName = songName.replaceAll(parenSubtitle, '').trim();
    if (isTitleMatching(cleanName, title)) return true;
    final tokens =
        title.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
    for (var i = 1; i < tokens.length; i++) {
      if (isTitleMatching(cleanName, tokens.sublist(i).join(' '))) return true;
    }
    return false;
  }


  /// CJK-leaning bracket content ending in a 1–2 digit season marker:
  /// 声生不息3, 我们的歌5. ASCII ids (SNH48) and 4-digit years (歌手2024) are
  /// deliberately excluded — the former are group names, the latter too
  /// ambiguous to trust here.
  static bool _looksLikeShowSeason(String bracketText) =>
      RegExp(r'^[\u4e00-\u9fa5A-Za-z·]+\d{1,2}$').hasMatch(bracketText) &&
      RegExp(r'[\u4e00-\u9fa5]').hasMatch(bracketText);

  /// Tokens that read like names but never are: descriptors that sit between
  /// a tag bracket and the song bracket ("【tag】周深 新歌《X》"). Kept as an
  /// exact-match set — see the multi-name gate in [cleanTitle].
  static const Set<String> _betweenJunk = {
    '新歌', '新歌首发', '演唱会', '全程', '直播', '预告', '花絮',
    '采访', '幕后', '排练', '首唱', 'reaction',
  };

  /// A single token that reads like one artist name: 2–7 name characters,
  /// nothing else. Descriptors (精选歌单合集, 总选跳, 弹奏…) can still slip
  /// through, which is why this gate only opens behind [_looksLikeShowSeason].
  static bool _looksLikeBareName(String t) =>
      RegExp(r'^[\u4e00-\u9fa5A-Za-z·]{2,7}$').hasMatch(t);

  // Normalize string for candidate matching verification
  static String _normalize(String input) {
    return input.replaceAll(RegExp(r'[^\u4e00-\u9fa5a-zA-Z0-9]'), '').toLowerCase();
  }

  /// Structural sanity gate for a DB-confirmed song name. NetEase hosts
  /// episode-level "纯享" tracks whose official title IS the whole video title
  /// ("【纯享】刘端端姚晓棠《霸王别姬》… | 音乐缘计划 | iQIYI奇艺音悦台") — they match
  /// the raw title verbatim and would score top, so anything still carrying
  /// bracket/bar markers or an episode-length title is not a song.
  static bool _isSaneOfficialTitle(String s) {
    if (s.isEmpty || s.length > 24) return false;
    return !RegExp(r'[《》【】\[\]|｜丨]').hasMatch(s);
  }

  static bool isTitleMatching(String candidateName, String targetTitle) {
    final cand = _normalize(candidateName);
    final target = _normalize(targetTitle);
    if (cand.isEmpty || target.isEmpty) return false;
    // A 2-char target like "11" would substring-match "2011"/"11月…" and pull
    // the wrong track's lyrics; exact equality is still trusted for short
    // names, but contains-matching requires a longer (specific) name.
    if (cand == target) return true;
    if (cand.length < 4 || target.length < 4) return false;
    return cand.contains(target) || target.contains(cand);
  }

  /// Parses LRC text into time-sorted lines.
  ///
  /// Handles the two forms the old parser silently dropped, both of which are
  /// everywhere in real .lrc files:
  ///  * `[mm:ss]` with no fractional part — previously skipped entirely, so
  ///    whole files could import as zero lines.
  ///  * Several timestamps sharing one line (`[00:12.00][01:30.00]副歌`) for a
  ///    repeated chorus — previously only the first was kept, so the chorus
  ///    never highlighted on later passes.
  static final RegExp _lrcTag = RegExp(r'\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]');

  static List<LyricLine> parseLrc(String lrcText) {
    if (lrcText.isEmpty) return [];

    final result = <LyricLine>[];

    for (final line in lrcText.split('\n')) {
      final matches = _lrcTag.allMatches(line).toList();
      if (matches.isEmpty) continue;

      final text = line.replaceAll(_lrcTag, '').trim();
      if (text.isEmpty) continue;

      for (final match in matches) {
        final minutes = int.parse(match.group(1)!);
        final seconds = int.parse(match.group(2)!);
        final fraction = match.group(3);
        // "5" means .5s, "05" means .05s, "050" means .050s.
        final millis = fraction == null
            ? 0
            : int.parse(fraction.padRight(3, '0').substring(0, 3));
        result.add(LyricLine(
          time: minutes * 60 + seconds + millis / 1000.0,
          text: text,
        ));
      }
    }

    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  /// Serialises lines back to LRC text (inverse of [parseLrc]).
  static String toLrc(List<LyricLine> lines) {
    final sb = StringBuffer();
    for (final line in lines) {
      // Round to whole milliseconds first: `sec.toStringAsFixed(2)` on a value
      // like 59.9996s would otherwise round up to "[mm:60.00]", which parseLrc
      // cannot read back.
      final totalMillis = (line.time * 1000).round();
      final min = totalMillis ~/ 60000;
      final secMillis = totalMillis % 60000;
      final sec = (secMillis / 1000).floor();
      final centis = (secMillis % 1000) ~/ 10;
      final tag = '[${min.toString().padLeft(2, '0')}:'
          '${sec.toString().padLeft(2, '0')}.${centis.toString().padLeft(2, '0')}]';
      sb.writeln('$tag${line.text}');
      if (line.translation != null && line.translation!.isNotEmpty) {
        sb.writeln('$tag${line.translation}');
      }
    }
    return sb.toString();
  }

  // NetEase Cloud Music Provider (Best Chinese coverage)
  static Future<LyricsResult?> fetchFromNetEase(String title, {String? artist}) async {
    final queries = [
      if (artist != null && artist.isNotEmpty) '$artist $title',
      title,
    ];

    for (final query in queries) {
      final searchUrl = 'https://music.163.com/api/search/get?s=${Uri.encodeComponent(query)}&type=1&limit=5';
      try {
        final searchBody = await _httpGet(searchUrl, headers: {'Referer': 'https://music.163.com'});
        if (searchBody != null) {
          final json = jsonDecode(searchBody);
          final songs = json['result']?['songs'] as List? ?? [];
          // Prefer the song whose artist appears in the query: "周深 不舍"
          // must yield 周深's 不舍, not the most popular 不舍 (a cover by
          // someone else) that happens to match the song name first.
          final queryNorm = _normalize(query);
          (Map, List<LyricLine>)? bestMatch;
          (Map, List<LyricLine>)? queryArtistMatch;
          (Map, List<LyricLine>)? echoMatch;
          for (final song in songs) {
            final songName = (song['name'] ?? '') as String;
            if (!matchesSongQuery(songName, query)) continue;
            final songId = song['id'];
            if (songId is! int || songId <= 0) continue;
            final lyricUrl = 'https://music.163.com/api/song/lyric?id=$songId&lv=-1&tv=-1';

            final lyricBody = await _httpGet(lyricUrl, headers: {'Referer': 'https://music.163.com'});
            if (lyricBody != null) {
              final lyricJson = jsonDecode(lyricBody);
              final rawLrc = (lyricJson['lrc']?['lyric'] ?? '') as String;
              final rawTrans = (lyricJson['tlyric']?['lyric'] ?? '') as String;

              final lines = parseLrc(rawLrc);
              final transLines = parseLrc(rawTrans);

              if (transLines.isNotEmpty) {
                // Both lists are time-sorted, so a single advancing pointer
                // keeps the merge O(n) instead of the previous O(n²)
                // firstWhere-scan per line.
                var ti = 0;
                for (var i = 0; i < lines.length; i++) {
                  final line = lines[i];
                  // Skip translations that are too early for this line.
                  while (ti < transLines.length &&
                      transLines[ti].time < line.time - 0.5) {
                    ti++;
                  }
                  // ti is now the first translation inside the window, if any.
                  if (ti < transLines.length &&
                      (transLines[ti].time - line.time).abs() < 0.5) {
                    lines[i] = LyricLine(
                      time: line.time,
                      text: line.text,
                      translation: transLines[ti].text,
                    );
                  }
                }
              }

              if (lines.isNotEmpty) {
                // Search-farm uploads are titled exactly like the query
                // ("遥遥 周深" for "周深 遥遥"): their title echoes BOTH the
                // song term and the artist term. They outrank real songs in
                // the result list, so rank them last — the real track (遥遥 by
                // 张云雷, say) must win the match.
                final songNameNorm = _normalize(songName);
                final isEcho = artist != null &&
                    artist.isNotEmpty &&
                    songNameNorm.isNotEmpty &&
                    songNameNorm.contains(_normalize(artist)) &&
                    songNameNorm.contains(_normalize(title));
                if (isEcho) {
                  echoMatch ??= (song, lines);
                  continue;
                }
                bestMatch ??= (song, lines);
                final artists = (song['artists'] as List? ?? [])
                    .where((a) => a is Map && a['name'] is String)
                    .map((a) => a['name'] as String)
                    .join(', ');
                if (queryNorm.isNotEmpty &&
                    artists.isNotEmpty &&
                    queryNorm.contains(_normalize(artists))) {
                  queryArtistMatch = (song, lines);
                  break;
                }
              }
            }
          }
          final chosen = queryArtistMatch ?? bestMatch ?? echoMatch;
          if (chosen != null) {
            final (chosenSong, lines) = chosen;
            final songName = (chosenSong['name'] ?? '') as String;
            final artists = (chosenSong['artists'] as List? ?? [])
                .where((a) => a is Map && a['name'] is String)
                .map((a) => a['name'] as String)
                .join(', ');
            return LyricsResult(
              source: 'netease',
              songTitle: songName,
              artistName: artists.isNotEmpty ? artists : artist,
              lines: lines,
            );
          }
        }
      } catch (e) {
        debugPrint('NetEase lyrics fetch error: $e');
      }
    }

    return null;
  }

  // Multi-source Waterfall Lyrics Orchestrator
  static Future<LyricsResult> autoFetchLyrics(String rawTitle) async {
    final cleaned = cleanTitle(rawTitle);
    final title = cleaned['songTitle']!;
    final artist = cleaned['artist'];

    // Step 1: NetEase (best Chinese coverage)
    final neteaseResult = await fetchFromNetEase(title, artist: artist);
    if (neteaseResult != null && neteaseResult.lines.isNotEmpty) {
      return neteaseResult;
    }

    // No placeholder lines: the UI renders its own empty state with a real
    // action, and fake "lyrics" would otherwise scroll past as if they were
    // the song's words.
    return LyricsResult(
      source: 'none',
      songTitle: title,
      artistName: artist,
      lines: const [],
    );
  }
}
