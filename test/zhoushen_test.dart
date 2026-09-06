import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/services/lyrics_engine.dart';

bool? _networkChecked;
bool _networkAvailable = false;

/// Probes connectivity to the lyric provider once per run; every live-NetEase
/// test starts with this so the suite stays green offline and in CI, and no
/// test result depends on NetEase's current ranking changing.
Future<void> _skipIfOffline() async {
  if (_networkChecked != null) {
    if (!_networkAvailable) markTestSkipped('requires music.163.com');
    return;
  }
  _networkChecked = true;
  try {
    final socket = await Socket.connect(
      'music.163.com',
      443,
      timeout: const Duration(seconds: 4),
    );
    socket.destroy();
    _networkAvailable = true;
  } catch (_) {
    markTestSkipped('requires music.163.com');
  }
}

void main() {
  test('cleanTitle: 周深-世界赠予我的 (with noise)', () {
    final res = LyricsEngine.cleanTitle(
      '周深-世界赠予我的 4k最高音质无损纯享 重混音修音版本【Hi-Res无损】',
      defaultArtist: '琉云星',
    );
    expect(res['songTitle'], '世界赠予我的');
    expect(res['artist'], '周深');
  });

  test('cleanTitle: 画绢 + 衣裳中国 (show tag disambiguation)', () {
    final res = LyricsEngine.cleanTitle(
      '【周深】《画绢》央视《衣裳中国》主题曲 完整版 4K',
      defaultArtist: '周深图文站',
    );
    expect(res['songTitle'], '画绢');
    expect(res['artist'], '周深');
  });

  test('cleanTitle: simple Artist - Song with spaces', () {
    final res = LyricsEngine.cleanTitle(
      '毛不易 - 一程山路',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '一程山路');
    expect(res['artist'], '毛不易');
  });

  test('cleanTitle: 邓紫棋《11》with book brackets', () {
    final res = LyricsEngine.cleanTitle(
      '邓紫棋《11》官方MV',
      defaultArtist: 'UP主',
    );
    expect(res['songTitle'], '11');
    expect(res['artist'], '邓紫棋');
  });

  test('cleanTitle: book bracket with artist after', () {
    final res = LyricsEngine.cleanTitle('《大鱼》周深');
    expect(res['songTitle'], '大鱼');
    expect(res['artist'], '周深');
  });

  test('cleanTitle: preserves normal tokens without noise keywords', () {
    final res = LyricsEngine.cleanTitle(
      '陈奕迅 - 十年',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '十年');
    expect(res['artist'], '陈奕迅');
  });

  test('cleanTitleWithValidation: 周深-世界赠予我的', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '周深-世界赠予我的 4k最高音质无损纯享 重混音修音版本【Hi-Res无损】',
      defaultArtist: '琉云星',
    );
    expect(res['songTitle'], '世界赠予我的');
    // Artist should be 周深 from either rule-based or cross-validation
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 【姚贝娜&amp;单依纯 心火】collab bracket (DB disambiguation)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【姚贝娜&amp;单依纯 心火】音乐是我们最珍贵的琥珀，致敬。',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '心火');
    expect(res['artist'], contains('姚贝娜'));
    expect(res['artist'], contains('单依纯'));
  });

  test('cleanTitle: 【姚贝娜&amp;单依纯 心火】with HTML entity & collab', () {
    final res = LyricsEngine.cleanTitle(
      '【姚贝娜&amp;单依纯 心火】音乐是我们最珍贵的琥珀，致敬。',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '心火');
    expect(res['artist'], '姚贝娜&单依纯');
  });

  test('cleanTitle: 【Artist&Artist Song】without HTML entity', () {
    final res = LyricsEngine.cleanTitle(
      '【张杰&张碧晨 只要平凡】我不是药神',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '只要平凡');
    expect(res['artist'], '张杰&张碧晨');
  });

  test('cleanTitle: show《音乐缘计划》+ song《全世界下雨》multi-bracket', () {
    final res = LyricsEngine.cleanTitle(
      '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '全世界下雨');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: show-vs-song book brackets', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '全世界下雨');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: repeated taps are idempotent (memoized)', () async {
    await _skipIfOffline();
    const raw = '【周深｜舞台】《音乐缘计划》第二季EP09带来《全世界下雨》舞台';
    final a =
        await LyricsEngine.cleanTitleWithValidation(raw, defaultArtist: '某UP主');
    final b =
        await LyricsEngine.cleanTitleWithValidation(raw, defaultArtist: '某UP主');
    expect(a, b);
    expect(a['songTitle'], isNotEmpty);
  });

  test('cleanTitle: show metadata after | separator is ignored', () {
    final res = LyricsEngine.cleanTitle(
      '【纯享】刘端端姚晓棠《霸王别姬》 舞台携手再现传世经典 | 音乐缘计划 | Melody Journey | iQIYI奇艺音悦台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '霸王别姬');
    expect(res['artist'], '刘端端姚晓棠');
  });

  test('cleanTitleWithValidation: show metadata after | separator', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【纯享】刘端端姚晓棠《霸王别姬》 舞台携手再现传世经典 | 音乐缘计划 | Melody Journey | iQIYI奇艺音悦台',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '霸王别姬');
    expect(res['artist'], '刘端端姚晓棠');
  });

  // Regression: 【show】 plain-artist 《song》. The leading bracket is the
  // show tag (声生不息3), not the artist — the plain text between the bracket
  // and the song bracket is. Used to return 声生不息3 as the artist, which
  // also poisoned the auto lyric search.
  test('cleanTitle: 【show】 plain artist 《song》 — plain artist wins', () {
    final res = LyricsEngine.cleanTitle(
      '【声生不息3】 黄绮珊&周深 《岁月》',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '岁月');
    expect(res['artist'], '黄绮珊&周深');
  });

  // The bracket artist must still win when nothing sits between bracket and
  // song, even with noise tokens in between (dropped by _noisyClean).
  test('cleanTitle: 【artist】 noise 《song》 keeps bracket artist', () {
    final res = LyricsEngine.cleanTitle(
      '【周深】 4K高清 《大鱼》',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '大鱼');
    expect(res['artist'], '周深');
  });

  // Regression (3.11.0 report): space-separated collab after a show bracket
  // with NO season digit. The & marker rule and the season-digit rule both
  // missed it, so the bracket show name survived as the artist and
  // validation laundered it (孙燕姿's 逆光 isn't by anyone in the title).
  test('cleanTitle: 【show】 space-separated collab 《song》', () {
    final res = LyricsEngine.cleanTitle(
      '【声生不息】陈楚生 周深 合作舞台《逆光》 爱在“逆光”中前行',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '逆光');
    expect(res['artist'], '陈楚生 周深');
  });

  // Regression (3.11.3, rule above in live form): the hinted "陈楚生 周深
  // 逆光" search carries two artist tokens; the match against the provider's
  // song name must survive them (isTitleMatching's length guard alone rejects
  // the 2-char 逆光 against the full query). Without this, the hinted query
  // yielded nothing and the bare 逆光 fallback resurrected 孙燕姿's studio
  // version — the 3.11.1 fix regressed.
  test('matchesSongQuery: multi-token artist hints still match short song names', () {
    expect(
      LyricsEngine.matchesSongQuery('逆光 (live)', '陈楚生 周深 逆光'),
      isTrue,
    );
    expect(
      LyricsEngine.matchesSongQuery('逆光', '陈楚生 周深 逆光'),
      isTrue,
    );
    expect(
      LyricsEngine.matchesSongQuery('岁月 (live)', '黄绮珊&周深 岁月'),
      isTrue,
    );
    expect(
      LyricsEngine.matchesSongQuery('世界赠予我的', '周深 世界赠予我的'),
      isTrue,
    );
  });

  // Regression (3.11.3): whole-word English glue noise (Cover/MV/Live) must
  // not eat real words — 周深 - Alive must split into artist 周深 / song
  // Alive, and Discover/Deliver-like tokens must survive _noisyClean.
  test('cleanTitle: English glue noise does not eat real words', () {
    final res = LyricsEngine.cleanTitle('周深 - Alive', defaultArtist: '某UP主');
    expect(res['songTitle'], 'Alive');
    expect(res['artist'], '周深');
  });

  // Regression (3.11.3): a standalone bar token must survive _noisyClean so
  // step 4's "Artist - Song" split still fires (the bar-split previously ran
  // before the pureSeparatorToken check and destroyed it).
  test('cleanTitle: standalone / separator still splits Artist / Song', () {
    final res = LyricsEngine.cleanTitle('周深 / 大鱼', defaultArtist: '某UP主');
    expect(res['songTitle'], '大鱼');
    expect(res['artist'], '周深');
  });

  // Regression (singer misrecognition report): the 4 songs 遥遥 / 有可能的
  // 夜晚 / 不舍 / 聊聊 are all 周深's, but cross-validation returned garbage
  // artists (the offline fallback) because the correct singer present in the
  // raw B站 title was never considered. Titles below are the real B站 titles.
  test('cleanTitleWithValidation: 遥遥-周深 (reversed dash)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '遥遥-周深',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '遥遥');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 不舍-周深 (reversed dash)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '不舍-周深',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '不舍');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 【纯净版】有可能的夜晚 周深 歌手2020 高清', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '【纯净版】有可能的夜晚 周深 歌手2020 高清',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '有可能的夜晚');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 周深翻唱《不舍》2025生日直播', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '周深翻唱《不舍》2025生日直播',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '不舍');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 周深 遥遥 (artist before song)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '周深 遥遥',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '遥遥');
    expect(res['artist'], '周深');
  });

  test('cleanTitleWithValidation: 聊聊-周深 (reversed dash)', () async {
    await _skipIfOffline();
    final res = await LyricsEngine.cleanTitleWithValidation(
      '聊聊-周深',
      defaultArtist: '某UP主',
    );
    expect(res['songTitle'], '聊聊');
    expect(res['artist'], '周深');
  });
}
