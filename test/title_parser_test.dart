import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:bilibeat/services/lyrics_engine.dart';

void main() {
  test('LyricsEngine.cleanTitle survives all 540 fixture Bilibili titles', () async {
    // The regression corpus is committed with the code, so this test runs on
    // any machine (including CI) instead of silently skipping when a
    // machine-local scratch file is missing.
    final file = File('test/fixtures/real_bilibili_titles.json');
    final List<dynamic> rawList =
        jsonDecode(await file.readAsString()) as List<dynamic>;
    expect(rawList, hasLength(540));

    for (final entry in rawList) {
      final title = entry['title'] as String;
      final uploader = entry['uploader'] as String;
      final parsed = LyricsEngine.cleanTitle(title, defaultArtist: uploader);
      expect(parsed['songTitle'], isNotNull,
          reason: 'songTitle was null for: $title');
      expect(parsed['songTitle'], isNotEmpty,
          reason: 'songTitle was empty for: $title');
    }
  });
}
