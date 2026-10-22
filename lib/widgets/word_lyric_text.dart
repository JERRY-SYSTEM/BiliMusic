import 'package:flutter/material.dart';

import '../models/lyric_line.dart';

/// One shaped paragraph for both layout and drawing. Selection boxes preserve
/// ligatures, Unicode boundaries, bidi direction and words spanning soft wraps.
/// Position changes repaint this paragraph without rebuilding the lyrics list.
class WordLyricText extends StatelessWidget {
  const WordLyricText({super.key, required this.line, required this.position,
    required this.offsetSeconds});

  final LyricLine line;
  final ValueNotifier<Duration> position;
  final double offsetSeconds;

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style;
    final direction = Directionality.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(builder: (context, constraints) {
      final painter = TextPainter(
        text: TextSpan(text: line.text, style: style),
        textDirection: direction, textScaler: scaler,
      )..layout(maxWidth: constraints.maxWidth);
      final height = painter.height;
      painter.dispose();
      return Semantics(label: line.text, child: SizedBox(
        width: constraints.maxWidth, height: height,
        child: CustomPaint(painter: _WordPainter(line: line, position: position,
          offsetSeconds: offsetSeconds, style: style, direction: direction, scaler: scaler)),
      ));
    });
  }
}

class _WordPainter extends CustomPainter {
  _WordPainter({required this.line, required this.position, required this.offsetSeconds,
    required this.style, required this.direction, required this.scaler}) : super(repaint: position);

  final LyricLine line;
  final ValueNotifier<Duration> position;
  final double offsetSeconds;
  final TextStyle style;
  final TextDirection direction;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    final color = style.color ?? Colors.white;
    final painter = TextPainter(
      text: TextSpan(text: line.text, style: style.copyWith(
        color: color.withValues(alpha: color.a * 0.32), shadows: const [],
      )), textDirection: direction, textScaler: scaler,
    )..layout(maxWidth: size.width);
    painter.paint(canvas, Offset.zero);
    final time = position.value.inMilliseconds + (offsetSeconds * 1000).round();
    final path = Path();
    var offset = 0;
    for (final word in line.words) {
      final boxes = painter.getBoxesForSelection(TextSelection(
        baseOffset: offset, extentOffset: offset + word.text.length,
      ));
      offset += word.text.length;
      var remaining = boxes.fold<double>(0, (total, box) => total + box.right - box.left) * word.progress(time);
      for (final box in boxes) {
        final width = box.right - box.left;
        final filled = remaining.clamp(0.0, width);
        if (filled > 0) {
          path.addRect(Rect.fromLTRB(
            box.direction == TextDirection.rtl ? box.right - filled : box.left,
            box.top,
            box.direction == TextDirection.rtl ? box.right : box.left + filled,
            box.bottom,
          ));
        }
        remaining -= width;
      }
    }
    painter.text = TextSpan(text: line.text, style: style);
    painter.layout(maxWidth: size.width);
    canvas.save();
    canvas.clipPath(path);
    painter.paint(canvas, Offset.zero);
    canvas.restore();
    painter.dispose();
  }

  @override
  bool shouldRepaint(_WordPainter oldDelegate) => oldDelegate.line != line ||
      oldDelegate.position != position || oldDelegate.offsetSeconds != offsetSeconds ||
      oldDelegate.style != style || oldDelegate.direction != direction || oldDelegate.scaler != scaler;
}
