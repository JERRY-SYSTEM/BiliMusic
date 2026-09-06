import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/services/lyrics_engine.dart';

void main() {
  group('matchesSongQuery', () {
    test('provider paren subtitle is stripped: 岁月 (live) matches 《岁月》',
        () {
      expect(LyricsEngine.matchesSongQuery('岁月 (live)', '岁月'), isTrue);
      expect(LyricsEngine.matchesSongQuery('岁月（Live）', '岁月'), isTrue);
      expect(
          LyricsEngine.matchesSongQuery('心火 (电影《心火》主题曲)', '心火'),
          isTrue);
    });

    test('compound "artist song" query matches short song names', () {
      // The regression: 岁月 (2 chars) could never pass isTitleMatching's
      // length guard against a compound query, so auto-searches for such
      // songs came up empty even when NetEase had the exact track.
      expect(LyricsEngine.matchesSongQuery('岁月', '黄绮珊&周深 岁月'), isTrue);
      expect(LyricsEngine.matchesSongQuery('岁月 (live)', '黄绮珊&周深 岁月'),
          isTrue);
      expect(LyricsEngine.matchesSongQuery('大鱼', '周深 大鱼'), isTrue);
    });

    test('bare short titles still match exactly', () {
      expect(LyricsEngine.matchesSongQuery('岁月', '岁月'), isTrue);
    });

    test('length guard against false positives is preserved', () {
      // The guard exists so a 2-char target like "11" never substring-matches
      // "2011". Renaming the helper must not weaken it: a short, unrelated
      // name must not match just because the query has a space in it.
      expect(LyricsEngine.matchesSongQuery('11', '2011 11月'), isFalse);
      expect(LyricsEngine.matchesSongQuery('晴天', '周杰伦 晴天'), isTrue);
      expect(LyricsEngine.matchesSongQuery('雨天', '周杰伦 晴天'), isFalse);
    });

    test('song-first compound queries are a documented limitation', () {
      // Only the post-space part is tried as the song side; "岁月 黄绮珊"
      // (song first) does not match. Search queries are composed
      // artist-first, so this stays acceptable.
      expect(LyricsEngine.matchesSongQuery('岁月', '岁月 黄绮珊'), isFalse);
    });
  });
}
