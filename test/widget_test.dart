
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:bilibeat/models/lyric_line.dart';
import 'package:bilibeat/services/lyrics_engine.dart';
import 'package:bilibeat/services/recommendation_engine.dart';
import 'package:bilibeat/models/playlist.dart';
import 'package:bilibeat/models/track.dart';
import 'package:bilibeat/widgets/marquee_text.dart';
import 'package:bilibeat/widgets/expand_from_card.dart';
import 'package:bilibeat/widgets/mini_player.dart';
import 'package:bilibeat/widgets/synced_lyrics_view.dart';
import 'package:bilibeat/widgets/playlist_detail_sheet.dart';

const _style = TextStyle(fontSize: 14, height: 1.25);

/// Mirrors how the mini player and the now-playing panel use the marquee: a
/// width-constrained Column whose siblings must not be pushed around.
Widget _host(String text, {double width = 160}) {
  return MaterialApp(
    home: Scaffold(
      body: Center(
        child: SizedBox(
          width: width,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MarqueeText(text: text, style: _style),
              const Text('sibling'),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('Playlist', () {
    test('tracks stay mutable even when constructed with a const literal', () {
      // A const constructor let `tracks: []` be promoted to an unmodifiable
      // const list, so adding to 收藏 threw at runtime.
      final pl = Playlist(id: 'favorites', name: '收藏', tracks: const []);
      expect(
        () => pl.tracks.add(const Track(
            id: 'a', bvid: 'a', cid: 1, title: 't', rawTitle: 't', uploader: 'u',
            coverUrl: '', duration: 1)),
        returnsNormally,
      );
      expect(pl.tracks, hasLength(1));
    });

    test('does not alias the list it was given', () {
      final source = <Track>[];
      final pl = Playlist(id: 'p', name: 'n', tracks: source);
      pl.tracks.add(const Track(
          id: 'a', bvid: 'a', cid: 1, title: 't', rawTitle: 't', uploader: 'u',
          coverUrl: '', duration: 1));
      expect(source, isEmpty);
    });
  });

  group('Track', () {
    test('copyWith preserves identity and only changes what is passed', () {
      const original = Track(
          id: 'BV1_2', bvid: 'BV1', cid: 2, title: '旧标题',
          rawTitle: '旧标题', uploader: '旧UP', coverUrl: 'c', duration: 100);
      final edited = original.copyWith(title: '新标题', uploader: '新UP');

      expect(edited.id, original.id);
      expect(edited.bvid, original.bvid);
      expect(edited.cid, original.cid);
      expect(edited.coverUrl, 'c');
      expect(edited.duration, 100);
      expect(edited.title, '新标题');
      // Identity is the id, so an edited track still matches in list lookups.
      expect(edited, equals(original));
      expect([original].indexOf(edited), 0);
    });

    test('survives a round trip through fromMap/toMap', () {
      const t = Track(
          id: 'BV1_2', bvid: 'BV1', cid: 2, title: '标题',
          rawTitle: '标题', uploader: 'UP', coverUrl: 'http://x', duration: 42);
      final back = Track.fromMap(t.toMap());
      expect(back.title, t.title);
      expect(back.uploader, t.uploader);
      expect(back.coverUrl, t.coverUrl);
      expect(back.duration, t.duration);
    });

    test('tolerates files written by older versions', () {
      final back = Track.fromMap({
        'id': 'BV1_2', 'bvid': 'BV1', 'cid': 2, 'title': 't',
        'uploader': 'u', 'coverUrl': '', 'duration': 5,
        // Fields removed in 2.2.0 — must not break loading.
        'uploaderFace': 'x', 'quality': 'hi', 'isDownloaded': 1,
        'localFilePath': '/tmp/a', 'addedAt': 123,
      });
      expect(back.id, 'BV1_2');
      expect(back.title, 't');
    });
  });

  group('TasteProfile', () {
    Track t(String id, String title, String uploader, {int duration = 200}) =>
        Track(
          id: id,
          bvid: id,
          cid: 1,
          title: title,
          rawTitle: title,
          uploader: uploader,
          coverUrl: '',
          duration: duration,
        );

    test('is empty with nothing to learn from', () {
      expect(
        TasteProfile.build(favourites: [], history: [], searches: []).isEmpty,
        isTrue,
      );
    });

    test('ranks a favourited UP主 above an unrelated track', () {
      final profile = TasteProfile.build(
        favourites: [t('a', '大鱼', '周深')],
        history: [],
        searches: [],
      );
      expect(
        profile.score(t('b', '不同的歌', '周深')),
        greaterThan(profile.score(t('c', '不同的歌', '别人'))),
      );
    });

    test('weights a favourite above a mere play', () {
      final fav = TasteProfile.build(
        favourites: [t('a', '大鱼', '周深')], history: [], searches: []);
      final played = TasteProfile.build(
        favourites: [], history: [t('a', '大鱼', '周深')], searches: []);
      expect(fav.score(t('b', '其他', '周深')),
          greaterThan(played.score(t('b', '其他', '周深'))));
    });

    test('matches Chinese titles without a segmenter', () {
      final profile = TasteProfile.build(
        favourites: [t('a', '大鱼海棠', 'UP1')], history: [], searches: []);
      // Shares the 海棠 bigram despite a different uploader.
      expect(profile.score(t('b', '海棠依旧', 'UP2')), greaterThan(0));
      expect(profile.score(t('c', '完全无关', 'UP3')), 0);
    });

    test('search history alone can drive the profile', () {
      final profile = TasteProfile.build(
        favourites: [], history: [], searches: ['周深 大鱼']);
      expect(profile.isEmpty, isFalse);
      expect(profile.score(t('b', '大鱼', 'someone')), greaterThan(0));
    });

    test('dropping search history drops its influence', () {
      final withHistory = TasteProfile.build(
        favourites: [], history: [], searches: ['古风']);
      final cleared =
          TasteProfile.build(favourites: [], history: [], searches: []);
      expect(withHistory.score(t('x', '古风翻唱', 'UP')), greaterThan(0));
      expect(cleared.isEmpty, isTrue);
    });

    test('knows what the user already has', () {
      final profile = TasteProfile.build(
        favourites: [t('owned', '大鱼', '周深')], history: [], searches: []);
      expect(profile.knownIds, contains('owned'));
    });

    test('seeds queries from the strongest signals first', () {
      final profile = TasteProfile.build(
        favourites: [t('a', '大鱼', '周深'), t('b', '化身孤岛的鲸', '周深')],
        history: [],
        searches: [],
      );
      expect(profile.seedQueries().first, '周深');
    });
  });

  group('RecommendationEngine.isSongLength', () {
    Track withDuration(int d) => Track(
        id: 'x', bvid: 'x', cid: 1, title: 't', rawTitle: 't', uploader: 'u',
        coverUrl: '', duration: d);

    test('keeps song-length uploads and drops long-form ones', () {
      expect(RecommendationEngine.isSongLength(withDuration(200)), isTrue);
      expect(RecommendationEngine.isSongLength(withDuration(360)), isTrue);
      expect(RecommendationEngine.isSongLength(withDuration(361)), isFalse);
      expect(RecommendationEngine.isSongLength(withDuration(7200)), isFalse);
    });

    test('drops entries with unknown duration', () {
      expect(RecommendationEngine.isSongLength(withDuration(0)), isFalse);
    });
  });

  group('LyricsEngine.parseLrc', () {
    test('accepts [mm:ss] with no fractional part', () {
      final lines = LyricsEngine.parseLrc('[00:12]第一句\n[01:05]第二句');
      expect(lines.map((l) => l.time), [12.0, 65.0]);
      expect(lines.first.text, '第一句');
    });

    test('expands a line carrying several timestamps', () {
      // A repeated chorus. Only the first stamp used to survive, so the line
      // never highlighted on later passes.
      final lines = LyricsEngine.parseLrc('[00:10.00][01:30.50]副歌');
      expect(lines.length, 2);
      expect(lines.map((l) => l.time), [10.0, 90.5]);
      expect(lines.every((l) => l.text == '副歌'), isTrue);
    });

    test('reads fractional digits by position, not magnitude', () {
      expect(LyricsEngine.parseLrc('[00:01.5]x').first.time, 1.5);
      expect(LyricsEngine.parseLrc('[00:01.05]x').first.time, 1.05);
      expect(LyricsEngine.parseLrc('[00:01.050]x').first.time, 1.05);
    });

    test('skips metadata tags and blank lyrics', () {
      final lines = LyricsEngine.parseLrc('[ar:周深]\n[00:03.00]\n[00:04.00]词');
      expect(lines.length, 1);
      expect(lines.single.text, '词');
    });

    test('sorts out-of-order stamps', () {
      final lines = LyricsEngine.parseLrc('[00:20.00]b\n[00:05.00]a');
      expect(lines.map((l) => l.text), ['a', 'b']);
    });
  });

  group('LyricsEngine.cleanTitle', () {
    test('splits "Artist - Title"', () {
      // The dash strip used to run first, so this never matched.
      final r = LyricsEngine.cleanTitle('周深 - 大鱼');
      expect(r['artist'], '周深');
      expect(r['songTitle'], '大鱼');
    });

    test('prefers an artist already found in brackets', () {
      final r = LyricsEngine.cleanTitle('【周深】大鱼');
      expect(r['artist'], '周深');
    });

    test('《》 names the song exactly', () {
      expect(LyricsEngine.cleanTitle('周深演唱《大鱼》现场')['songTitle'], '大鱼');
    });

    test('never returns an empty title', () {
      expect(LyricsEngine.cleanTitle('4K 1080P Live')['songTitle'], isNotEmpty);
    });
  });

  group('TrackNotifier', () {
    Track track({String title = 't', String cover = ''}) => Track(
        id: 'a', bvid: 'a', cid: 1, title: title, rawTitle: title, uploader: 'u',
        coverUrl: cover, duration: 1);

    test('notifies when only the metadata of the same track changes', () {
      // Track equality is id-only, so a plain ValueNotifier swallowed this and
      // the docked player kept rendering the pre-edit title and cover.
      final notifier = TrackNotifier(track());
      var notified = 0;
      notifier.addListener(() => notified++);

      notifier.value = track(title: '新标题', cover: '/covers/new.jpg');

      expect(notified, 1);
      expect(notifier.value!.title, '新标题');
      expect(notifier.value!.coverUrl, '/covers/new.jpg');
    });

    test('ignores a re-assignment of the very same instance', () {
      final same = track();
      final notifier = TrackNotifier(same);
      var notified = 0;
      notifier.addListener(() => notified++);

      notifier.value = same;

      expect(notified, 0);
    });
  });

  group('MarqueeText', () {
    testWidgets('overflowing text keeps a single-line height', (tester) async {
      await tester.pumpWidget(_host('short'));
      final shortHeight = tester.getSize(find.byType(MarqueeText)).height;

      await tester.pumpWidget(_host('a title far too long to ever fit here'));
      final longHeight = tester.getSize(find.byType(MarqueeText)).height;

      expect(longHeight, shortHeight,
          reason: 'a long title must not grow the row');
    });

    testWidgets('height is stable once the scroll animation runs',
        (tester) async {
      await tester.pumpWidget(_host('a title far too long to ever fit here'));
      final firstFrame = tester.getSize(find.byType(MarqueeText));
      final siblingBefore = tester.getTopLeft(find.text('sibling'));

      // The original bug measured text in a post-frame callback and re-laid
      // out afterwards, shifting everything below it.
      await tester.pump(const Duration(milliseconds: 16));
      await tester.pump(const Duration(seconds: 2));
      await tester.pump(const Duration(seconds: 2));

      expect(tester.getSize(find.byType(MarqueeText)), firstFrame);
      expect(tester.getTopLeft(find.text('sibling')), siblingBefore);
      expect(tester.takeException(), isNull);
    });

    testWidgets('never exceeds the width it was given', (tester) async {
      await tester.pumpWidget(_host('a title far too long to ever fit here'));
      await tester.pump(const Duration(seconds: 2));

      expect(tester.getSize(find.byType(MarqueeText)).width, 160);
      expect(tester.takeException(), isNull);
    });

    testWidgets('scrolls at a constant velocity, with no dwell at the wrap',
        (tester) async {
      const title = 'a title far too long to ever fit here';
      await tester.pumpWidget(_host(title));
      await tester.pump(); // post-frame callback starts the controller

      // One cycle is the text plus the gap; the second copy trails exactly one
      // cycle behind, so the wrap is a modular step, not a jump back to zero.
      final travel = tester.getSize(find.text(title).first).width + 44;

      double offsetX() => tester
          .widget<Transform>(find.descendant(
              of: find.byType(MarqueeText), matching: find.byType(Transform)))
          .transform
          .getTranslation()
          .x;

      const step = Duration(milliseconds: 200);
      final deltas = <double>[];
      var previous = offsetX();
      for (var i = 0; i < 150; i++) {
        await tester.pump(step);
        final current = offsetX();
        var advanced = previous - current; // offsets run negative
        if (advanced < 0) advanced += travel; // crossed the wrap
        deltas.add(advanced);
        previous = current;
      }

      expect(deltas.reduce((a, b) => a + b), greaterThan(travel),
          reason: 'the sampling must actually cross the wrap point');
      for (final d in deltas) {
        // A dwell shows up as 0, a jump back to the start as a wrong step.
        expect(d, closeTo(deltas.first, 0.5));
      }
    });

    testWidgets('short text is not scrolled', (tester) async {
      await tester.pumpWidget(_host('short'));
      await tester.pump(const Duration(seconds: 2));

      // A non-scrolling marquee renders exactly one Text child.
      expect(
        find.descendant(
            of: find.byType(MarqueeText), matching: find.text('short')),
        findsOneWidget,
      );
    });
  });

  group('SyncedLyricsView', () {
    List<LyricLine> lines() => List.generate(
        30, (i) => LyricLine(time: i * 4.0, text: '第 $i 行歌词内容'));

    Widget host({
      required List<LyricLine> data,
      ValueNotifier<Duration>? position,
      void Function(double)? onSeek,
      VoidCallback? onOpenEditor,
      bool calibrating = false,
      void Function(double)? onCalibrateTap,
      bool autoFollow = true,
      double offset = 0.0,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 500,
            child: SyncedLyricsView(
              lines: data,
              positionNotifier: position ?? ValueNotifier(Duration.zero),
              onSeek: onSeek,
              onOpenEditor: onOpenEditor,
              calibrating: calibrating,
              onCalibrateTap: onCalibrateTap,
              autoFollow: autoFollow,
              offset: offset,
            ),
          ),
        ),
      );
    }

    testWidgets('empty state offers the editor action', (tester) async {
      var opened = false;
      await tester
          .pumpWidget(host(data: const [], onOpenEditor: () => opened = true));

      expect(find.text('暂无同步歌词'), findsOneWidget);
      await tester.tap(find.text('搜索或粘贴歌词'));
      expect(opened, isTrue);
    });

    testWidgets('tapping a line seeks to its timestamp when not calibrating',
        (tester) async {
      double? sought;
      await tester
          .pumpWidget(host(data: lines(), onSeek: (s) => sought = s));
      await tester.pump();

      await tester.tap(find.text('第 2 行歌词内容'));
      expect(sought, 8.0);
    });

    testWidgets('user scrolling suspends auto-follow and offers to resume',
        (tester) async {
      final position = ValueNotifier(Duration.zero);
      await tester.pumpWidget(host(data: lines(), position: position));
      await tester.pump();

      expect(find.text('回到当前'), findsNothing);

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pump();
      expect(find.text('回到当前'), findsOneWidget,
          reason: 'auto-scroll must yield while the user is reading ahead');

      // Playback continuing must not yank the list back mid-browse.
      position.value = const Duration(seconds: 40);
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('回到当前'), findsOneWidget);

      await tester.tap(find.text('回到当前'));
      await tester.pumpAndSettle();
      expect(find.text('回到当前'), findsNothing);
    });

    testWidgets('armed, tapping a line reports tap calibration offset',
        (tester) async {
      final applied = <double>[];
      await tester.pumpWidget(host(
        data: lines(),
        position: ValueNotifier(const Duration(seconds: 10)),
        calibrating: true,
        onCalibrateTap: applied.add,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('第 2 行歌词内容'));
      await tester.pumpAndSettle();

      // Line 2 time is 8.0s, playhead is at 10.0s. Difference - reaction time (0.2s) = 1.8s
      expect(applied, hasLength(1));
      expect(applied.single, closeTo(1.8, 0.01));
    });

    testWidgets('calibration mode shows tap instruction hint', (tester) async {
      await tester.pumpWidget(
          host(data: lines(), calibrating: true, onCalibrateTap: (_) {}));
      await tester.pumpAndSettle();
      expect(find.text('点击正在唱的那行歌词'), findsOneWidget);
    });

    testWidgets('unarmed, a drag scrolls and calibrates nothing',
        (tester) async {
      final applied = <double>[];
      await tester.pumpWidget(host(data: lines(), onCalibrateTap: applied.add));
      await tester.pump();

      await tester.drag(find.byType(ListView), const Offset(0, -200));
      await tester.pumpAndSettle();

      expect(applied, isEmpty);
      expect(find.text('回到当前'), findsOneWidget);
    });

    testWidgets('a preview with a frozen clock never scrolls itself back',
        (tester) async {
      // Auto-follow yanking the list back to 0:00 five seconds after every
      // scroll made the lyrics unreadable in the editor's preview.
      await tester.pumpWidget(host(data: lines(), autoFollow: false));
      await tester.pumpAndSettle();

      await tester.drag(find.byType(ListView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final scrolled = tester.getTopLeft(find.text('第 5 行歌词内容')).dy;

      await tester.pump(const Duration(seconds: 8));
      await tester.pumpAndSettle();

      expect(tester.getTopLeft(find.text('第 5 行歌词内容')).dy, scrolled);
      expect(find.text('回到当前'), findsNothing);
    });
  });

  group('ExpandFromCard', () {
    testWidgets('grows the card rect to the full screen without relayout',
        (tester) async {
      final controller = AnimationController(
        vsync: tester,
        duration: const Duration(milliseconds: 300),
      );
      addTearDown(controller.dispose);

      const from = Rect.fromLTWH(12, 700, 376, 68);
      await tester.pumpWidget(MaterialApp(
        home: ExpandFromCard(
          animation: controller,
          from: from,
          child: const Scaffold(body: Center(child: Text('player'))),
        ),
      ));

      // The page is laid out at full size from the very first frame — only the
      // clip moves — so its size must not change as the morph runs.
      final closed = tester.getSize(find.text('player'));
      controller.value = 0.5;
      await tester.pump();
      expect(tester.getSize(find.text('player')), closed);

      controller.value = 1.0;
      await tester.pump();
      expect(tester.getSize(find.text('player')), closed);
      // Settled, the transition gets out of the way entirely.
      expect(find.byType(ClipRRect), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('MiniPlayer', () {
    Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

    testWidgets('renders an empty state with no track', (tester) async {
      await tester.pumpWidget(wrap(MiniPlayer(
        currentTrack: null,
        isPlaying: false,
        positionNotifier: ValueNotifier(Duration.zero),
        durationNotifier: ValueNotifier(Duration.zero),
        onPlayPause: () {},
        onNext: () {},
        onTap: () {},
      )));

      expect(find.text('选一首歌开始播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    const track = Track(
      id: 'BV1_p1',
      bvid: 'BV1',
      cid: 1,
      title: '一首标题非常非常长的歌曲用来触发滚动效果',
      rawTitle: '一首标题非常非常长的歌曲用来触发滚动效果',
      uploader: '某位 UP 主',
      coverUrl: '',
      duration: 200,
    );

    testWidgets('progress fills from the left edge, not from the middle',
        (tester) async {
      await tester.pumpWidget(wrap(MiniPlayer(
        currentTrack: track,
        isPlaying: true,
        positionNotifier: ValueNotifier(const Duration(seconds: 50)),
        durationNotifier: ValueNotifier(const Duration(seconds: 200)),
        onPlayPause: () {},
        onNext: () {},
        onTap: () {},
        onSeek: (_) {},
      )));
      await tester.pump(const Duration(milliseconds: 300));

      final track_ = tester.getRect(find.byType(FractionallySizedBox));
      final lane = tester.getRect(find.ancestor(
          of: find.byType(FractionallySizedBox),
          matching: find.byType(ClipRRect).last));

      // Left-anchored and a quarter across. Shrink-wrapped, the fill sized its
      // own track and the whole bar grew outwards from the centre.
      expect(track_.left, lane.left);
      expect(track_.width, closeTo(lane.width * 0.25, 1.0));
    });

    testWidgets('dragging the progress bar seeks', (tester) async {
      Duration? sought;
      await tester.pumpWidget(wrap(MiniPlayer(
        currentTrack: track,
        isPlaying: true,
        positionNotifier: ValueNotifier(Duration.zero),
        durationNotifier: ValueNotifier(const Duration(seconds: 200)),
        onPlayPause: () {},
        onNext: () {},
        onTap: () {},
        onSeek: (d) => sought = d,
      )));
      await tester.pump(const Duration(milliseconds: 300));

      final bar = tester.getRect(find.byType(FractionallySizedBox));
      final lane = tester.getRect(find.ancestor(
          of: find.byType(FractionallySizedBox),
          matching: find.byType(ClipRRect).last));
      final gesture = await tester.startGesture(
          Offset(lane.left + 4, bar.center.dy));
      await gesture.moveBy(Offset(lane.width / 2, 0));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(sought, isNotNull);
      expect(sought!.inSeconds, closeTo(100, 6));
    });

    testWidgets('shows the track and toggles play', (tester) async {
      var toggled = false;
      await tester.pumpWidget(wrap(MiniPlayer(
        currentTrack: const Track(
          id: 'BV1_1',
          bvid: 'BV1',
          cid: 1,
          title: '一首标题非常非常长的歌曲用来触发滚动效果',
          rawTitle: '一首标题非常非常长的歌曲用来触发滚动效果',
          uploader: '某位 UP 主',
          coverUrl: '',
          duration: 200,
        ),
        isPlaying: true,
        positionNotifier: ValueNotifier(const Duration(seconds: 50)),
        durationNotifier: ValueNotifier(const Duration(seconds: 200)),
        onPlayPause: () => toggled = true,
        onNext: () {},
        onTap: () {},
      )));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
      await tester.tap(find.byIcon(Icons.pause_rounded));
      expect(toggled, isTrue);
      expect(tester.takeException(), isNull);
    });
  });

  group('PlaylistDetailSheet', () {
    testWidgets('renders empty state title as 暂无曲目 without subtitle and cover button on right', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PlaylistDetailSheet(
            playlist: Playlist(id: 'test_pl', name: '测试歌单', tracks: []),
            onSelectTrack: (_, {queue}) {},
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(find.text('暂无曲目'), findsOneWidget);
      expect(find.text('歌单暂无曲目'), findsNothing);
      expect(find.text('在搜索页点 + 添加'), findsNothing);
      expect(find.byIcon(Icons.image_outlined), findsOneWidget);
    });
  });
}
