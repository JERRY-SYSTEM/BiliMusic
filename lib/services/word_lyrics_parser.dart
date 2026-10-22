import 'dart:convert';
import 'dart:io';

import '../models/lyric_line.dart';
import 'qrc_decoder.dart';

/// Parsers retain the provider's word boundaries, whitespace and millisecond
/// timestamps. A malformed word stream must never expose timing tags as text.
class WordLyricsParser {
  static final _line = RegExp(r'^\[(\d+),(\d+)\](.*)$');
  static final _yrcWord = RegExp(r'\((\d+),(\d+),\d+\)');
  static final _krcWord = RegExp(r'<(\d+),(\d+),\d+>');
  static final _qrcWord = RegExp(r'\((\d+),(\d+)\)');

  static List<LyricLine> yrc(String text) => _parse(text, _yrcWord);

  static List<LyricLine> krc(String text) {
    final lines = _parse(text, _krcWord, relative: true);
    final language = RegExp(r'^\[language:([^\]]+)\]', multiLine: true).firstMatch(text);
    if (language == null) return lines;
    // Translation metadata is optional; corrupt metadata must not discard the
    // original, correctly timed lyrics.
    try {
      final data = jsonDecode(utf8.decode(base64Decode(language.group(1)!.trim())));
      for (final item in data['content'] as List) {
        if (item['type'] != 1) continue;
        final translations = item['lyricContent'] as List;
        for (var i = 0; i < lines.length && i < translations.length; i++) {
          final row = translations[i];
          if (row is List && row.isNotEmpty && row.first is String) {
            lines[i] = lines[i].withTranslation(row.first as String);
          }
        }
      }
    } catch (_) { /* Keep original lyrics. */ }
    return lines;
  }

  static List<LyricLine> qrc(String text) {
    return _parse(qrcContent(text), _qrcWord, suffix: true);
  }

  static String qrcContent(String text) => decodeEntities(
    RegExp(r'LyricContent="([\s\S]*?)"').firstMatch(text)?.group(1) ?? text);

  static List<LyricLine> _parse(String text, RegExp wordTag, {
    bool relative = false, bool suffix = false,
  }) {
    final result = <LyricLine>[];
    for (final raw in const LineSplitter().convert(text)) {
      final match = _line.firstMatch(raw.trimLeft());
      if (match == null) continue;
      final start = int.parse(match[1]!);
      final end = start + int.parse(match[2]!);
      final content = match[3]!.replaceAll(RegExp(r'\[\d+,\d+\]'), '');
      final tags = wordTag.allMatches(content).toList();
      final words = <LyricWord>[];
      for (var i = 0; i < tags.length; i++) {
        final tag = tags[i];
        final wordStart = int.parse(tag[1]!) + (relative ? start : 0);
        final wordEnd = wordStart + int.parse(tag[2]!);
        final value = suffix
            ? content.substring(i == 0 ? 0 : tags[i - 1].end, tag.start)
            : content.substring(tag.end, i + 1 == tags.length ? content.length : tags[i + 1].start);
        words.add(LyricWord(text: value, startMs: wordStart, endMs: wordEnd));
      }
      if (tags.isEmpty && content.isNotEmpty) {
        // Plain content inside a timed line is valid, but has no word timings.
        if (RegExp(r'[<>\[\]]|\(\d+,').hasMatch(content)) continue;
        result.add(LyricLine(time: start / 1000, endMs: end, text: content));
      } else {
        final value = words.map((word) => word.text).join();
        result.add(LyricLine(time: start / 1000, endMs: end, text: value,
          words: value.isEmpty ? const [] : List.unmodifiable(words)));
      }
    }
    result.sort((a, b) => a.time.compareTo(b.time));
    return result;
  }

  static String decryptKrc(String content) {
    final bytes = base64Decode(content);
    if (bytes.length < 4 || ascii.decode(bytes.take(4).toList()) != 'krc1') {
      throw const FormatException('Invalid KRC header');
    }
    const key = [64, 71, 97, 119, 94, 50, 116, 71, 81, 54, 49, 45, 206, 210, 110, 105];
    final compressed = List<int>.generate(bytes.length - 4,
      (i) => bytes[i + 4] ^ key[i % key.length]);
    return utf8.decode(zlib.decode(compressed));
  }

  static String decryptQrc(String content) => QrcDecoder.decode(content);

  static String decodeEntities(String text) => text.replaceAllMapped(
    RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);'), (match) {
      final entity = match[1]!;
      const named = {'amp': '&', 'lt': '<', 'gt': '>', 'quot': '"', 'apos': "'"};
      if (named.containsKey(entity)) return named[entity]!;
      final value = entity.startsWith('#x')
          ? int.tryParse(entity.substring(2), radix: 16)
          : int.tryParse(entity.substring(1));
      return value == null || value > 0x10ffff || value < 0
          ? match[0]! : String.fromCharCode(value);
    });
}
