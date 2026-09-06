import 'package:flutter/material.dart';

/// A single rounded placeholder block with a sweeping highlight.
class Shimmer extends StatefulWidget {
  final double width;
  final double height;
  final BorderRadius borderRadius;

  const Shimmer({
    super.key,
    required this.width,
    required this.height,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1300),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _controller.value;
          return Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              gradient: LinearGradient(
                begin: Alignment(-1.0 + 2.0 * t, 0.0),
                end: Alignment(1.0 + 2.0 * t, 0.0),
                colors: const [
                  Color(0x14FFFFFF),
                  Color(0x30FFFFFF),
                  Color(0x14FFFFFF),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// A track-row skeleton: circular art + two text bars.
class SkeletonTrackTile extends StatelessWidget {
  const SkeletonTrackTile({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          const Shimmer(
            width: 56,
            height: 56,
            borderRadius: BorderRadius.all(Radius.circular(12)),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Shimmer(width: double.infinity, height: 14),
                const SizedBox(height: 8),
                Shimmer(
                  width: MediaQuery.of(context).size.width * 0.4,
                  height: 11,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

