import 'package:bilimusic/models/lyric_line.dart';
import 'package:bilimusic/widgets/synced_lyrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('line changes start without waiting for the previous animation',
      (tester) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SyncedLyricsView(
          lines: [
            LyricLine(time: 0, text: 'First line'),
            LyricLine(time: 0.1, text: 'Second line'),
            LyricLine(time: 0.2, text: 'Third line'),
          ],
          positionNotifier: position,
          autoFollow: false,
        ),
      ),
    ));

    double? targetFontSize(String text) => tester
        .widget<AnimatedDefaultTextStyle>(find.ancestor(
          of: find.text(text),
          matching: find.byType(AnimatedDefaultTextStyle),
        ))
        .style
        .fontSize;

    position.value = const Duration(milliseconds: 100);
    await tester.pump();
    expect(targetFontSize('Second line'), 30);

    // No time elapses to complete the 420 ms transition or a 150 ms throttle.
    position.value = const Duration(milliseconds: 200);
    await tester.pump();
    expect(targetFontSize('Third line'), 30);
    expect(targetFontSize('Second line'), 24);

    await tester.pumpWidget(const SizedBox.shrink());
    position.dispose();
  });
}
