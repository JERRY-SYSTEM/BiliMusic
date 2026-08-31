import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import '../theme/motion.dart';
import '../models/lyric_line.dart';

/// Synced lyrics that highlight and auto-scroll to the active line.
///
/// Two things make this feel right rather than merely functional:
///  * Browsing wins. While the user is scrolling, auto-scroll yields and a
///    "回到当前" pill appears; it resumes on its own a few seconds later.
///  * Lines are centred against *measured* heights and viewport-proportional
///    padding, so the first and last lines can reach the middle too.
///
/// Calibration is tap-to-set: while [calibrating] is true the user taps the
/// line they hear being sung *right now*; the view computes the offset from
/// the playhead (minus a fixed reaction-time compensation) and reports it
/// through [onCalibrateTap].
class SyncedLyricsView extends StatefulWidget {
  final List<LyricLine> lines;
  final ValueNotifier<Duration> positionNotifier;
  final Function(double position)? onSeek;
  final VoidCallback? onOpenEditor;
  final double offset;

  /// Calibration mode. While on, tapping a line reports a correction instead
  /// of seeking.
  final bool calibrating;

  /// Called when the user taps a line during calibration. The value is the
  /// absolute offset (in seconds) that should be applied to every line.
  final void Function(double offsetSeconds)? onCalibrateTap;

  /// Whether the view should follow playback. False for a preview driven by a
  /// clock that never advances.
  final bool autoFollow;
  final bool showTranslation;

  const SyncedLyricsView({
    super.key,
    required this.lines,
    required this.positionNotifier,
    this.onSeek,
    this.onOpenEditor,
    this.offset = 0.0,
    this.calibrating = false,
    this.onCalibrateTap,
    this.autoFollow = true,
    this.showTranslation = true,
  });

  @override
  State<SyncedLyricsView> createState() => _SyncedLyricsViewState();
}

class _SyncedLyricsViewState extends State<SyncedLyricsView> {
  final ScrollController _scrollController = ScrollController();
  final Map<String, double> _heightCache = {};

  int _activeIndex = 0;
  DateTime _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  /// While true the user is in control and auto-scroll stands down.
  bool _userBrowsing = false;
  int? _selectionIndex;
  Timer? _resumeTimer;

  double _viewportHeight = 400;
  double _topPadding = 160;
  double _lineWidth = 320;

  /// System font scale from the build context; measurement must apply the
  /// same scale the Text widgets render with, or rows misalign once the user
  /// raises the OS font size.
  TextScaler _textScaler = TextScaler.noScaling;

  static const Duration _browseGrace = Duration(seconds: 5);

  /// Average human auditory reaction time. The user always taps slightly
  /// *after* they hear the line start, so we subtract this from the raw
  /// measurement to compensate.
  static const double _reactionCompensation = 0.20;

  @override
  void initState() {
    super.initState();
    widget.positionNotifier.addListener(_onPosition);
  }

  @override
  void didUpdateWidget(covariant SyncedLyricsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.positionNotifier != widget.positionNotifier) {
      oldWidget.positionNotifier.removeListener(_onPosition);
      widget.positionNotifier.addListener(_onPosition);
    }
    if (oldWidget.lines != widget.lines ||
        oldWidget.offset != widget.offset ||
        oldWidget.calibrating != widget.calibrating) {
      _heightCache.clear();
      _lastUpdate = DateTime.fromMillisecondsSinceEpoch(0);
      _selectionIndex = null;
      _onPosition(force: true);
    }
  }

  @override
  void dispose() {
    _resumeTimer?.cancel();
    widget.positionNotifier.removeListener(_onPosition);
    _scrollController.dispose();
    super.dispose();
  }

  void _onPosition({bool force = false}) {
    if (widget.lines.isEmpty) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastUpdate).inMilliseconds < 150) return;
    _lastUpdate = now;

    final posSec =
        (widget.positionNotifier.value.inMilliseconds / 1000.0) - widget.offset;
    final newIndex = _findActiveIndex(posSec);
    if (newIndex != _activeIndex || force) {
      setState(() => _activeIndex = newIndex);
      if (widget.autoFollow && !_userBrowsing) {
        _scrollToActive();
      }
    }
  }

  int _findActiveIndex(double posSec) {
    final lines = widget.lines;
    int lo = 0;
    int hi = lines.length - 1;
    int ans = 0;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (lines[mid].time <= posSec) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  void _beginBrowsing() {
    _resumeTimer?.cancel();
    if (!_userBrowsing && mounted) setState(() => _userBrowsing = true);
    _updateSelection();
  }

  void _updateSelection() {
    if (!_scrollController.hasClients || widget.lines.isEmpty) return;
    final anchor = _scrollController.offset;
    var accumulated = 0.0;
    var closestIndex = 0;
    var closestDistance = double.infinity;
    for (var index = 0; index < widget.lines.length; index++) {
      final height = _itemHeight(widget.lines[index], false);
      final center = accumulated + height / 2;
      final distance = (center - anchor).abs();
      if (distance < closestDistance) {
        closestDistance = distance;
        closestIndex = index;
      }
      if (center > anchor && distance > closestDistance) break;
      accumulated += height;
    }
    if (_selectionIndex != closestIndex && mounted) {
      setState(() => _selectionIndex = closestIndex);
    }
  }

  void _seekToSelection() {
    final index = _selectionIndex;
    if (index == null || widget.onSeek == null) return;
    Haptics.selection();
    widget.onSeek!(widget.lines[index].time + widget.offset);
    setState(() => _selectionIndex = null);
    _resumeFollowing();
  }

  void _scheduleResume() {
    if (!widget.autoFollow) return;
    _resumeTimer?.cancel();
    _resumeTimer = Timer(_browseGrace, _resumeFollowing);
  }

  void _resumeFollowing() {
    _resumeTimer?.cancel();
    if (!mounted) return;
    setState(() {
      _userBrowsing = false;
      _selectionIndex = null;
    });
    _scrollToActive();
  }

  void _scrollToActive({bool animate = true}) {
    if (!_scrollController.hasClients || widget.lines.isEmpty) return;

    double accumulated = 0.0;
    for (int i = 0; i < _activeIndex && i < widget.lines.length; i++) {
      accumulated += _itemHeight(widget.lines[i], false);
    }

    final activeHeight = _itemHeight(widget.lines[_activeIndex], true);
    final target = _topPadding +
        accumulated -
        (_viewportHeight * 0.42) +
        (activeHeight / 2);
    final clamped =
        target.clamp(0.0, _scrollController.position.maxScrollExtent);

    if (!animate) {
      _scrollController.jumpTo(clamped);
      return;
    }
    _scrollController.animateTo(
      clamped,
      duration: AppMotion.slow,
      curve: AppMotion.standard,
    );
  }

  // ---------------------------------------------------------------------------
  // Tap-to-set calibration
  // ---------------------------------------------------------------------------

  bool get _canCalibrate =>
      widget.calibrating && widget.onCalibrateTap != null && widget.lines.isNotEmpty;

  void _handleCalibrationTap(int index) {
    final posSec = widget.positionNotifier.value.inMilliseconds / 1000.0;
    final lineTime = widget.lines[index].time;
    // The user taps *after* hearing the line start, so the raw difference
    // overshoots by roughly their reaction time. Subtract it.
    final raw = posSec - lineTime;
    final compensated = raw - _reactionCompensation;
    final offset = double.parse(compensated.toStringAsFixed(2));
    Haptics.selection();
    widget.onCalibrateTap!(offset);
  }

  // ---------------------------------------------------------------------------
  // Layout helpers
  // ---------------------------------------------------------------------------

  /// Measured row height, memoised per (text, state, width, font scale).
  double _itemHeight(LyricLine line, bool isActive) {
    final key = '${line.text} ${line.translation ?? ''} $isActive'
        ' ${_lineWidth.round()} ${_textScaler.scale(100)}';
    final cached = _heightCache[key];
    if (cached != null) return cached;

    double height = 36.0; // vertical padding: 18 + 18
    height += _measureText(line.text, isActive ? 30.0 : 24.0,
        isActive ? FontWeight.w800 : FontWeight.w500);
    if (widget.showTranslation &&
        line.translation != null &&
        line.translation!.isNotEmpty) {
      height += 4.0;
      height += _measureText(line.translation!, isActive ? 16.0 : 14.0,
          FontWeight.w500);
    }

    if (_heightCache.length > 400) _heightCache.clear();
    _heightCache[key] = height;
    return height;
  }

  double _measureText(String text, double fontSize, FontWeight weight) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(fontSize: fontSize, fontWeight: weight, height: 1.35),
      ),
      textDirection: TextDirection.ltr,
      textScaler: _textScaler,
    )..layout(maxWidth: _lineWidth);
    final height = painter.height;
    painter.dispose();
    return height;
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (widget.lines.isEmpty) return _emptyState();

    return LayoutBuilder(
      builder: (context, constraints) {
        _viewportHeight = constraints.maxHeight;
        _lineWidth = constraints.maxWidth;
        _topPadding = _viewportHeight * 0.42;
        _textScaler = MediaQuery.textScalerOf(context);

        return Stack(
          children: [
            NotificationListener<ScrollNotification>(
              onNotification: (notification) {
                if (notification is ScrollStartNotification &&
                    notification.dragDetails != null) {
                  _beginBrowsing();
                } else if (notification is ScrollUpdateNotification &&
                    _userBrowsing) {
                  _updateSelection();
                } else if (notification is ScrollEndNotification &&
                    _userBrowsing) {
                  if (widget.onSeek == null) _scheduleResume();
                }
                return false;
              },
              child: ListView.builder(
                controller: _scrollController,
                padding: EdgeInsets.only(
                  top: _topPadding,
                  bottom: _viewportHeight * 0.5,
                ),
                // builder instead of List.generate: only visible lines are
                // built, so a long song does not instantiate (and animate)
                // hundreds of off-screen tiles.
                itemCount: widget.lines.length,
                itemBuilder: (context, index) => _lineTile(index),
              ),
            ),
            if (_canCalibrate)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: IgnorePointer(child: Center(child: _calibrationHint())),
              )
            else if (_userBrowsing &&
                _selectionIndex != null &&
                widget.onSeek != null)
              _selectionProgress()
            else if (_userBrowsing && widget.autoFollow)
              Positioned(
                left: 0,
                right: 0,
                bottom: 8,
                child: Center(child: _resumePill()),
              ),
          ],
        );
      },
    );
  }

  Widget _lineTile(int index) {
    final line = widget.lines[index];
    final isActive = index == _activeIndex;
    final isSelected = _userBrowsing && index == _selectionIndex;
    final focusIndex = _selectionIndex ?? _activeIndex;
    final distance = (index - focusIndex).abs();
    final opacity = isActive || isSelected
        ? 1.0
        : (distance == 1 ? 0.70 : (distance == 2 ? 0.52 : 0.36));

    return InkWell(
      borderRadius: BorderRadius.circular(AppRadius.md),
      onTap: _canCalibrate
          ? () => _handleCalibrationTap(index)
          : (widget.onSeek == null
              ? null
              : () {
                  Haptics.selection();
                  widget.onSeek!(line.time + widget.offset);
                  _resumeFollowing();
                }),
      child: AnimatedOpacity(
        duration: AppMotion.slow,
        curve: AppMotion.standard,
        opacity: opacity,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 18, horizontal: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              AnimatedDefaultTextStyle(
                duration: AppMotion.slow,
                curve: AppMotion.standard,
                style: TextStyle(
                  color: isSelected
                      ? context.palette.textSecondary
                      : context.palette.textPrimary,
                  fontSize: isActive ? 30 : 24,
                  height: 1.25,
                  fontWeight: isActive ? FontWeight.w800 : FontWeight.w500,
                  letterSpacing: isActive ? -0.4 : -0.2,
                  shadows: isActive
                      ? [Shadow(color: context.palette.accent50, blurRadius: 18)]
                      : null,
                ),
                child: Text(line.text),
              ),
              if (widget.showTranslation &&
                  line.translation != null &&
                  line.translation!.isNotEmpty) ...[
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: AppMotion.slow,
                  curve: AppMotion.standard,
                  style: TextStyle(
                    color: isActive ? context.palette.accent : context.palette.textMuted,
                    fontSize: isActive ? 16 : 14,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                  ),
                  child: Text(line.translation!),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _calibrationHint() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.backgroundElevated,
        borderRadius: BorderRadius.circular(AppRadius.pill),
        border: Border.all(color: context.palette.accent30),
        boxShadow: const [
          BoxShadow(color: AppColors.black45, blurRadius: 16, offset: Offset(0, 4)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.touch_app_rounded, color: context.palette.accent, size: 15),
          SizedBox(width: 7),
          Text(
            '点击正在唱的那行歌词',
            style: TextStyle(
              color: AppColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _selectionProgress() {
    final index = _selectionIndex!;
    final duration = Duration(
      milliseconds: ((widget.lines[index].time + widget.offset) * 1000)
          .round()
          .clamp(0, 1 << 31)
          .toInt(),
    );
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    final label = duration.inHours > 0
        ? '${duration.inHours}:$minutes:$seconds'
        : '$minutes:$seconds';
    return Positioned(
      top: _viewportHeight * 0.42 - 100,
      left: 0,
      right: 0,
      child: SizedBox(
        height: 200,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned(
              left: 0,
              right: 52,
              child: Container(height: 1, color: context.palette.hairline),
            ),
            Positioned(
              right: 0,
              child: GestureDetector(
                key: const Key('lyricSelectionPlayButton'),
                onTap: _seekToSelection,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: context.palette.surfaceDeep.withValues(alpha: 0.86),
                    borderRadius: BorderRadius.circular(AppRadius.pill),
                  ),
                  child: Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.play_arrow_rounded,
                            size: 14, color: context.palette.textSecondary),
                        const SizedBox(width: 2),
                        Text(
                          label,
                          style: TextStyle(
                            color: context.palette.textSecondary,
                            fontSize: 11,
                            height: 1,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _resumePill() {
    return GestureDetector(
      onTap: () {
        Haptics.selection();
        _resumeFollowing();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.backgroundElevated,
          borderRadius: BorderRadius.circular(AppRadius.pill),
          border: Border.all(color: context.palette.accent30),
          boxShadow: const [
            BoxShadow(color: AppColors.black45, blurRadius: 16, offset: Offset(0, 4)),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.my_location_rounded, color: context.palette.accent, size: 15),
            SizedBox(width: 6),
            Text('回到当前',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }

  Widget _emptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.lyrics_outlined, color: AppColors.textFaint, size: 40),
          const SizedBox(height: 12),
          const Text(
            '暂无同步歌词',
            style: TextStyle(color: AppColors.textMuted, fontSize: 16),
          ),
          if (widget.onOpenEditor != null) ...[
            const SizedBox(height: 6),
            const Text(
              '可以搜索、或直接粘贴 .lrc 文本',
              style: TextStyle(color: AppColors.textFaint, fontSize: 12.5),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: widget.onOpenEditor,
              icon: const Icon(Icons.search, size: 16),
              label: const Text('搜索或粘贴歌词'),
              style: OutlinedButton.styleFrom(
                foregroundColor: context.palette.accent,
                side: BorderSide(color: context.palette.accent30),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.pill)),
                padding:
                    const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
