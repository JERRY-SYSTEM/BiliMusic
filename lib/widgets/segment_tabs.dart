import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/haptics.dart';

/// Sliding-pill tab selector: a highlighted pill glides between labels as the
/// driving [animation] advances from `0` to `labels.length - 1`.
///
/// The pill is measured against the label rows themselves (keys are owned
/// internally), so it tracks drags/fades exactly. On the very first frame the
/// child RenderBoxes do not exist yet; instead of the old
/// `(context as Element).markNeedsBuild()` post-frame hack — which rebuilt the
/// entire parent dialog/page — the retry is a local setState on this widget.
class SegmentTabs extends StatefulWidget {
  final List<String> labels;
  final Animation<double> animation;
  final ValueChanged<int> onTap;
  final double fontSize;

  const SegmentTabs({
    super.key,
    required this.labels,
    required this.animation,
    required this.onTap,
    this.fontSize = 23,
  });

  @override
  State<SegmentTabs> createState() => _SegmentTabsState();
}

class _SegmentTabsState extends State<SegmentTabs> {
  final GlobalKey _rowKey = GlobalKey();
  late List<GlobalKey> _itemKeys;

  @override
  void initState() {
    super.initState();
    _itemKeys = List.generate(widget.labels.length, (_) => GlobalKey());
  }

  @override
  void didUpdateWidget(covariant SegmentTabs oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.labels.length != widget.labels.length) {
      _itemKeys = List.generate(widget.labels.length, (_) => GlobalKey());
    }
  }

  int get _activeIndex => widget.animation.value
      .round()
      .clamp(0, widget.labels.length - 1);

  void _scheduleRetry() {
    // First frame only: children paint before their RenderBoxes exist.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() {});
    });
  }

  RenderBox? _boxOf(GlobalKey key) =>
      key.currentContext?.findRenderObject() as RenderBox?;

  @override
  Widget build(BuildContext context) {
    return Stack(
      key: _rowKey,
      children: [
        AnimatedBuilder(
          animation: widget.animation,
          builder: (context, _) {
            final rowBox = _boxOf(_rowKey);
            final boxes = [for (final k in _itemKeys) _boxOf(k)];
            if (rowBox == null || boxes.any((b) => b == null)) {
              _scheduleRetry();
              return const SizedBox.shrink();
            }
            // Interpolate between the two labels the fraction sits between.
            final t = widget.animation.value
                .clamp(0.0, (widget.labels.length - 1).toDouble());
            final i = t.floor().clamp(0, widget.labels.length - 2);
            final frac = t - i;
            final from = boxes[i]!;
            final to = boxes[i + 1]!;
            final offFrom =
                from.localToGlobal(Offset.zero, ancestor: rowBox);
            final offTo = to.localToGlobal(Offset.zero, ancestor: rowBox);
            return Positioned(
              left: offFrom.dx + (offTo.dx - offFrom.dx) * frac,
              width: from.size.width +
                  (to.size.width - from.size.width) * frac,
              top: 0,
              bottom: 0,
              child: Container(
                decoration: BoxDecoration(
                  color: AppColors.accent14,
                  borderRadius: BorderRadius.circular(AppRadius.pill),
                  border: Border.all(color: AppColors.accent30),
                ),
              ),
            );
          },
        ),
        Row(
          children: [
            for (var i = 0; i < widget.labels.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              _item(i),
            ],
          ],
        ),
      ],
    );
  }

  Widget _item(int index) {
    final active = _activeIndex == index;
    return GestureDetector(
      key: _itemKeys[index],
      behavior: HitTestBehavior.opaque,
      onTap: () {
        Haptics.selection();
        widget.onTap(index);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Text(
          widget.labels[index],
          style: TextStyle(
            color: active ? AppColors.textPrimary : AppColors.textMuted,
            fontSize: widget.fontSize,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
          ),
        ),
      ),
    );
  }
}
