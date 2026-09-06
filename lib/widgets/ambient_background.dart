import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/bili_http.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import 'cached_cover_image.dart';

/// Full-screen ambient backdrop whose glow is derived from the current cover
/// art's dominant color — the signature "Apple Music" look. Falls back to the
/// brand pink when there is no cover or extraction fails.
///
/// Performance:
///  * The dominant color is extracted from a 24×24 decode (tiny) and cached per
///    URL, so it runs once per track.
///  * The glow lives in a [RepaintBoundary]; only the ~600 ms color transition
///    repaints, then it is static.
class AmbientBackground extends StatefulWidget {
  final String? coverUrl;

  const AmbientBackground({super.key, this.coverUrl});

  @override
  State<AmbientBackground> createState() => _AmbientBackgroundState();
}

class _AmbientBackgroundState extends State<AmbientBackground> {
  static final HttpClient _client = biliHttpClient();

  static final Map<String, Color> _colorCache = {};
  static const int _maxCacheSize = 100;
  static const Color _fallback = AppColors.accent;

  /// How far above the top edge the aura's centre sits, and how tall it is,
  /// both as fractions of the screen. Tuned so the colour is gone about one
  /// song row below where the first row of content begins.
  static const double _auraTop = 0.30;
  static const double _auraHeight = 0.74;

  Color _color = _fallback;
  int _token = 0;

  @override
  void initState() {
    super.initState();
    _resolve(widget.coverUrl);
  }

  @override
  void didUpdateWidget(covariant AmbientBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.coverUrl != widget.coverUrl) {
      _resolve(widget.coverUrl);
    }
  }

  Future<void> _resolve(String? url) async {
    // Bump the token before every branch: a fallback/cache apply from an old
    // coverUrl must not be able to win over a newer one still extracting.
    final token = ++_token;
    if (url == null || url.isEmpty) {
      _apply(_fallback);
      return;
    }
    final cached = _colorCache[url];
    if (cached != null) {
      _apply(cached);
      return;
    }
    try {
      final color = await _extractDominantColor(url);
      // Evict oldest entries when cache grows too large.
      if (_colorCache.length >= _maxCacheSize) {
        _colorCache.remove(_colorCache.keys.first);
      }
      _colorCache[url] = color;
      if (mounted && token == _token) _apply(color);
    } catch (e) {
      debugPrint('Ambient color extraction failed: $e');
      if (mounted && token == _token) _apply(_fallback);
    }
  }

  void _apply(Color c) {
    if (c != _color && mounted) {
      setState(() => _color = c);
    }
  }

  /// Decodes a tiny thumbnail and averages its pixels, biased toward saturated
  /// regions so vivid artwork dominates over neutral areas.
  static Future<Color> _extractDominantColor(String url) async {
    final Uint8List bytes;
    if (CachedCoverImage.isLocalPath(url)) {
      bytes = await File(CachedCoverImage.localPathOf(url)).readAsBytes();
    } else {
      // Ask the CDN for a thumbnail: we only ever decode 24×24, so pulling the
      // full-resolution cover would waste the bytes entirely.
      final req = await _client
          .getUrl(Uri.parse(CachedCoverImage.sizedUrl(url, 64, 64)));
      req.headers.set('Referer', 'https://www.bilibili.com/');
      req.headers.set('User-Agent', kBiliUserAgent);
      final res = await req.close();
      if (res.statusCode != HttpStatus.ok) {
        await res.drain<void>();
        throw Exception('HTTP ${res.statusCode}');
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in res) {
        builder.add(chunk);
      }
      bytes = builder.takeBytes();
    }

    final codec = await ui.instantiateImageCodec(
      bytes,
      targetWidth: 24,
      targetHeight: 24,
    );
    final frame = await codec.getNextFrame();
    final image = frame.image;
    final byteData = await image.toByteData(); // rawRgba
    image.dispose();
    codec.dispose();
    if (byteData == null) return _fallback;

    double r = 0, g = 0, b = 0, wSum = 0;
    final pixelCount = byteData.lengthInBytes ~/ 4;
    for (int i = 0; i < pixelCount; i++) {
      final o = i * 4;
      final rr = byteData.getUint8(o);
      final gg = byteData.getUint8(o + 1);
      final bb = byteData.getUint8(o + 2);
      final aa = byteData.getUint8(o + 3);
      if (aa < 128) continue;

      final rF = rr / 255.0, gF = gg / 255.0, bF = bb / 255.0;
      final mx = rF > gF ? (rF > bF ? rF : bF) : (gF > bF ? gF : bF);
      final mn = rF < gF ? (rF < bF ? rF : bF) : (gF < bF ? gF : bF);
      final sat = mx == 0 ? 0.0 : (mx - mn) / mx;

      final w = 0.15 + sat * sat; // emphasize vivid pixels
      r += rr * w;
      g += gg * w;
      b += bb * w;
      wSum += w;
    }
    if (wSum == 0) return _fallback;

    final base = Color.fromARGB(
      255,
      (r / wSum).round().clamp(0, 255),
      (g / wSum).round().clamp(0, 255),
      (b / wSum).round().clamp(0, 255),
    );

    // Push saturation/lightness into an elegant, glow-friendly range.
    final hsl = HSLColor.fromColor(base);
    return hsl
        .withSaturation(hsl.saturation.clamp(0.45, 0.85))
        .withLightness(hsl.lightness.clamp(0.38, 0.6))
        .toColor();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Stack(
      children: [
        // Pure black everywhere. The glow is the exception, not the default.
        const Positioned.fill(child: ColoredBox(color: AppColors.background)),

        // One aura, hanging off the top edge, gone by the time the first row
        // of content starts. It used to be two blobs across the whole screen,
        // which tinted every list and left nothing actually black.
        Positioned(
          top: -size.height * _auraTop,
          left: -size.width * 0.25,
          right: -size.width * 0.25,
          height: size.height * _auraHeight,
          child: RepaintBoundary(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(begin: _fallback, end: _color),
              duration: AppMotion.ambient,
              curve: AppMotion.standard,
              builder: (context, animated, _) {
                final c = animated ?? _fallback;
                return DecoratedBox(
                  // No circle clip: the gradient's own falloff is the edge, and
                  // a clipped circle on a screen-wide box gives the aura a
                  // visible rim.
                  decoration: BoxDecoration(
                    gradient: RadialGradient(
                      colors: [
                        c.withValues(alpha: 0.40),
                        c.withValues(alpha: 0.15),
                        Colors.transparent,
                      ],
                      stops: const [0.0, 0.55, 1.0],
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        // Hard floor: whatever the aura's falloff does, everything below the
        // first screenful of content is exactly the background colour.
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          height: size.height * 0.62,
          child: const IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Colors.transparent, AppColors.background],
                  stops: [0.5, 0.98],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
