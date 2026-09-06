import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/models/lyric_line.dart';
import 'package:bilibeat/models/playlist.dart';
import 'package:bilibeat/models/track.dart';

/// Round-trips through the same jsonEncode/jsonDecode the database layer
/// uses, so a field that survives toMap/fromMap but not JSON (e.g. a non-
/// encodable type) is caught here, not on a user's disk.
Map<String, dynamic> throughJson(Map<String, dynamic> map) =>
    Map<String, dynamic>.from(jsonDecode(jsonEncode(map)));

Track _track({String id = 'BV1_p1', String? audioUrl}) => Track(
      id: id,
      bvid: 'BV1',
      cid: 42,
      title: '显示标题',
      rawTitle: '【原始】B站视频标题',
      uploader: 'UP主',
      coverUrl: 'https://example.com/cover.jpg',
      duration: 245,
      audioUrl: audioUrl,
    );

void main() {
  group('Track', () {
    test('full JSON round-trip preserves every field', () {
      final t = _track(audioUrl: 'https://example.com/a.m4a');
      final rt = Track.fromMap(throughJson(t.toMap()));

      expect(rt.id, t.id);
      expect(rt.bvid, t.bvid);
      expect(rt.cid, t.cid);
      expect(rt.title, t.title);
      expect(rt.rawTitle, t.rawTitle);
      expect(rt.uploader, t.uploader);
      expect(rt.coverUrl, t.coverUrl);
      expect(rt.duration, t.duration);
      expect(rt.audioUrl, t.audioUrl);
      expect(rt, t); // identity is the id — rehydrated tracks must compare equal
    });

    test('null audioUrl survives the round-trip', () {
      final rt = Track.fromMap(throughJson(_track().toMap()));
      expect(rt.audioUrl, isNull);
    });

    test('tolerates unknown extra keys (older writer)', () {
      final map = throughJson(_track().toMap());
      map['uploaderFace'] = 'https://example.com/face.jpg';
      map['quality'] = 30280;
      map['isDownloaded'] = true;
      final rt = Track.fromMap(map);
      expect(rt.id, 'BV1_p1');
      expect(rt.title, '显示标题');
    });

    test('tolerates missing keys (newer writer) with safe defaults', () {
      final rt = Track.fromMap(throughJson({'id': 'x'}));
      expect(rt.id, 'x');
      expect(rt.title, isNotEmpty);
      expect(rt.uploader, isNotEmpty);
      expect(rt.cid, 0);
      expect(rt.duration, 0);
      // rawTitle falls back to the *persisted* title; when both are absent
      // there is nothing to fall back to and it stays empty.
      expect(rt.rawTitle, isEmpty);
    });
  });

  group('Playlist', () {
    test('JSON round-trip preserves playlist and nested tracks', () {
      final pl = Playlist(
        id: 'pl_1',
        name: '测试歌单',
        coverUrl: '/covers/pl_1.jpg',
        tracks: [_track(), _track(id: 'BV1_p2')],
      );

      // Serialised exactly the way DatabaseService._persistPlaylists does it.
      final map = pl.toMap();
      map['tracks'] = pl.tracks.map((t) => t.toMap()).toList();
      final decoded = throughJson(map);

      final tracks = (decoded['tracks'] as List<dynamic>)
          .map((t) => Track.fromMap(Map<String, dynamic>.from(t)))
          .toList();
      final rt = Playlist.fromMap(decoded, tracks: tracks);

      expect(rt.id, pl.id);
      expect(rt.name, pl.name);
      expect(rt.coverUrl, pl.coverUrl);
      expect(rt.tracks, pl.tracks);
      expect(rt.tracks.length, 2);
    });

    test('null coverUrl is omitted and stays null', () {
      final pl = Playlist(id: 'pl_2', name: '无封面', tracks: []);
      final decoded = throughJson(pl.toMap());
      expect(decoded.containsKey('coverUrl'), isFalse);
      expect(Playlist.fromMap(decoded).coverUrl, isNull);
    });

    test('tracks list is always growable (add-to-favorites regression)', () {
      final rt = Playlist.fromMap({'id': 'p', 'name': 'n'});
      rt.tracks.add(_track()); // must not throw
      expect(rt.tracks, hasLength(1));
    });
  });

  group('LyricLine', () {
    test('JSON round-trip preserves time, text and translation', () {
      final line = LyricLine(time: 72.5, text: '歌词', translation: 'translation');
      final rt = LyricLine.fromMap(throughJson(line.toMap()));
      expect(rt.time, 72.5);
      expect(rt.text, '歌词');
      expect(rt.translation, 'translation');
    });

    test('accepts integer time values from JSON', () {
      final rt = LyricLine.fromMap(throughJson({'time': 72, 'text': 'x'}));
      expect(rt.time, 72.0);
      expect(rt.translation, isNull);
    });
  });

  group('LyricsResult', () {
    test('JSON round-trip preserves source, titles and lines', () {
      final res = LyricsResult(
        source: 'netease',
        songTitle: '歌名',
        artistName: '歌手',
        lines: [
          LyricLine(time: 0, text: '第一行'),
          LyricLine(time: 12.34, text: '第二行', translation: '译'),
        ],
      );
      final rt = LyricsResult.fromMap(throughJson(res.toMap()));
      expect(rt.source, 'netease');
      expect(rt.songTitle, '歌名');
      expect(rt.artistName, '歌手');
      expect(rt.lines, hasLength(2));
      expect(rt.lines[1].time, 12.34);
      expect(rt.lines[1].translation, '译');
    });

    test('nullable titles survive and default source is none', () {
      final rt = LyricsResult.fromMap(
          throughJson(const LyricsResult(source: 'user', lines: []).toMap()));
      expect(rt.source, 'user');
      expect(rt.songTitle, isNull);
      expect(rt.artistName, isNull);

      final bare = LyricsResult.fromMap(throughJson({'lines': []}));
      expect(bare.source, 'none');
      expect(bare.lines, isEmpty);
    });
  });
}
