import 'package:bilimusic/models/lyric_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final lines = [
    LyricLine(time: 1, text: 'First'),
    LyricLine(time: 3, text: 'Second'),
  ];

  test('no line is active before the first timestamp', () {
    expect(findActiveLyricIndex(lines, Duration.zero), -1);
    expect(findActiveLyricIndex(lines, const Duration(milliseconds: 999)), -1);
    expect(findActiveLyricIndex(const [], const Duration(seconds: 5)), -1);
  });

  test('each line becomes active at its timestamp, never before it', () {
    expect(findActiveLyricIndex(lines, const Duration(seconds: 1)), 0);
    expect(findActiveLyricIndex(lines, const Duration(milliseconds: 2999)), 0);
    expect(findActiveLyricIndex(lines, const Duration(seconds: 3)), 1);
    expect(findActiveLyricIndex(lines, const Duration(seconds: 10)), 1);
  });

  test('positive and negative calibration offsets apply at the boundary', () {
    expect(findActiveLyricIndex(lines, const Duration(milliseconds: 2500),
        offsetSeconds: 0.5), 1);
    expect(findActiveLyricIndex(lines, const Duration(milliseconds: 3499),
        offsetSeconds: -0.5), 0);
    expect(findActiveLyricIndex(lines, const Duration(milliseconds: 3500),
        offsetSeconds: -0.5), 1);
  });
}
