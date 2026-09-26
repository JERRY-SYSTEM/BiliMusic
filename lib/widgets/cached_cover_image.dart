import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import 'package:path_provider/path_provider.dart';
import '../services/app_database.dart';
import '../services/bili_http.dart';
import '../services/track_enrichment_service.dart';
import '../models/track.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// A cover image that downscales on decode and disk-caches a CDN-resized
/// thumbnail.
///
/// Performance notes:
///  * Requests a size-matched thumbnail from Bilibili's image CDN (which
///    supports `@{w}w_{h}h` resizing) instead of the full-resolution original,
///    cutting download bytes and decode cost dramatically in long lists.
///  * Uses one shared [HttpClient] so connections are pooled and reused rather
///    than spawning (and leaking) a new client per image.
///  * Never touches the filesystem synchronously during `build` — that used to
///    put a blocking `existsSync` on the raster path for every local cover.
class CachedCoverImage extends StatefulWidget {
  final String url;
  final double width;
  final double height;
  final BoxFit fit;
  final Track? track;

  const CachedCoverImage({
    super.key,
    required this.url,
    required this.width,
    required this.height,
    this.fit = BoxFit.cover,
    this.track,
  });

  /// Appends Bilibili CDN resize params when the host supports them.
  static String sizedUrl(String url, int w, int h) {
    if (url.isEmpty) return url;
    final uri = Uri.tryParse(url);
    if (uri == null) return url;
    final host = uri.host;
    final isBili = host.contains('hdslb.com') ||
        host.contains('biliimg.com') ||
        host.contains('bilivideo.com') ||
        host.contains('bilibili.com');
    if (!isBili) return url;
    if (url.contains('@')) return url; // already parameterized
    return '$url@${w}w_${h}h_1e_1c.webp';
  }

  static bool isLocalPath(String url) =>
      url.startsWith('/') || url.startsWith('file://');

  static String localPathOf(String url) =>
      url.startsWith('file://') ? url.substring('file://'.length) : url;

  @override
  State<CachedCoverImage> createState() => _CachedCoverImageState();
}

enum _CoverStatus { deferred, loading, ready, failed }

class _CoverLoadResult {
  const _CoverLoadResult({this.file, this.statusCode});

  final File? file;
  final int? statusCode;
}

class _CachedCoverImageState extends State<CachedCoverImage> {
  static final HttpClient _client =
      biliHttpClient(connectionTimeout: const Duration(seconds: 15),
          maxConnectionsPerHost: 8);

  // Avoid requesting absurdly large thumbnails.
  static const int _maxEdge = 1080;

  // Deduplicates concurrent downloads of the same URL: two list rows showing
  // the same cover would otherwise both write to the same `.part` file and
  // interleave truncate/append, renaming a corrupt file into the cache.
  static final Map<String, Future<_CoverLoadResult>> _inFlight = {};

  File? _file;
  int? _httpStatus;
  _CoverStatus _status = _CoverStatus.deferred;
  late String _loadKey;
  bool _loadStarted = false;
  bool _visibilityCheckScheduled = false;
  ScrollableState? _scrollable;
  ScrollPosition? _scrollPosition;

  @override
  void initState() {
    super.initState();
    _loadKey = widget.url;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextScrollable = Scrollable.maybeOf(context);
    final nextPosition = nextScrollable?.position;
    if (!identical(nextPosition, _scrollPosition)) {
      _scrollPosition?.removeListener(_scheduleVisibilityCheck);
      _scrollable = nextScrollable;
      _scrollPosition = nextPosition;
      _scrollPosition?.addListener(_scheduleVisibilityCheck);
    }
    if (_shouldDeferNetEaseWork) {
      _scheduleVisibilityCheck();
    } else {
      _startLoading();
    }
  }

  @override
  void didUpdateWidget(covariant CachedCoverImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final sourceChanged = oldWidget.url != widget.url ||
        oldWidget.track?.id != widget.track?.id;
    if (sourceChanged) {
      _loadKey = widget.url;
      _loadStarted = false;
      setState(() {
        _file = null;
        _httpStatus = null;
        _status = _CoverStatus.deferred;
      });
      if (_shouldDeferNetEaseWork) {
        _scheduleVisibilityCheck();
      } else {
        _startLoading();
      }
    }
  }

  @override
  void dispose() {
    _scrollPosition?.removeListener(_scheduleVisibilityCheck);
    super.dispose();
  }

  bool get _isNetEaseCover {
    final host = Uri.tryParse(widget.url)?.host.toLowerCase() ?? '';
    return host == 'music.163.com' ||
        host.endsWith('.music.163.com') ||
        host == 'music.126.net' ||
        host.endsWith('.music.126.net');
  }

  bool get _shouldDeferNetEaseWork {
    if (_isNetEaseCover) return true;
    final track = widget.track;
    if (track == null) return false;
    return track.musicSource == 'netease' ||
        track.musicSource.isEmpty ||
        track.musicId.isEmpty ||
        track.coverUrl.isEmpty;
  }

  void _scheduleVisibilityCheck() {
    if (_loadStarted || _visibilityCheckScheduled || !mounted) return;
    _visibilityCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _visibilityCheckScheduled = false;
      if (!mounted || _loadStarted) return;
      if (!_shouldDeferNetEaseWork || _isVisibleOnScreen()) {
        _startLoading();
      }
    });
  }

  bool _isVisibleOnScreen() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.attached || !renderObject.hasSize) {
      return false;
    }
    final origin = renderObject.localToGlobal(Offset.zero);
    final bounds = origin & renderObject.size;
    Rect visibleBounds = Offset.zero & MediaQuery.sizeOf(context);
    final scrollRenderObject = _scrollable?.context.findRenderObject();
    if (scrollRenderObject is RenderBox && scrollRenderObject.attached && scrollRenderObject.hasSize) {
      final scrollOrigin = scrollRenderObject.localToGlobal(Offset.zero);
      visibleBounds = visibleBounds.intersect(scrollOrigin & scrollRenderObject.size);
    }
    return bounds.overlaps(visibleBounds) && bounds.width > 0 && bounds.height > 0;
  }

  void _startLoading() {
    if (_loadStarted || !mounted) return;
    _loadStarted = true;
    setState(() => _status = _CoverStatus.loading);
    _loadImage();
  }

  int get _targetW {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return (widget.width * dpr).round().clamp(1, _maxEdge);
  }

  int get _targetH {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    return (widget.height * dpr).round().clamp(1, _maxEdge);
  }

  void _settle(String token, _CoverLoadResult result) {
    if (!mounted || token != _loadKey) return;
    setState(() {
      _file = result.file;
      _httpStatus = result.statusCode;
      _status = result.file == null ? _CoverStatus.failed : _CoverStatus.ready;
    });
  }

  Future<void> _loadImage() async {
    final String token = _loadKey;
    var sourceUrl = widget.url;
    final track = widget.track;
    var cacheOwner = track;
    if (track != null &&
        (track.musicSource.isEmpty || track.musicId.isEmpty || track.coverUrl.isEmpty)) {
      if (sourceUrl.isEmpty) {
        final enriched = await TrackEnrichmentService.enrich(track);
        if (!mounted || token != _loadKey) return;
        cacheOwner = enriched ?? track;
        sourceUrl = enriched?.coverUrl ?? '';
      } else {
        TrackEnrichmentService.enrichInBackground(track);
      }
    }
    if (sourceUrl.isEmpty) {
      _settle(token, const _CoverLoadResult());
      return;
    }

    // Local file path (e.g. a user-picked custom cover): use it directly,
    // no download or CDN resizing needed.
    if (CachedCoverImage.isLocalPath(sourceUrl)) {
      final f = File(CachedCoverImage.localPathOf(sourceUrl));
      _settle(token, _CoverLoadResult(file: await f.exists() ? f : null));
      return;
    }

    try {
      final fetchUrl =
          CachedCoverImage.sizedUrl(sourceUrl, _targetW, _targetH);

      // Application Support, not the temp dir: iOS/Android may purge temp
      // under storage pressure, which silently re-downloaded every cover.
      final supportDir = await getApplicationSupportDirectory();
      final cacheDir = Directory('${supportDir.path}/bilimusic_covers');
      if (!await cacheDir.exists()) {
        await cacheDir.create(recursive: true);
      }
      final md5Key = md5.convert(utf8.encode(fetchUrl)).toString();
      final file = File('${cacheDir.path}/img_$md5Key.img');

      // Persist ownership before touching the network. Cache management can
      // now show the song while its visible cover is still downloading, and
      // exact paths avoid misclassifying uncommon thumbnail sizes as “其它”.
      if (cacheOwner != null) {
        await AppDatabase.registerCoverCache(
          cacheOwner,
          fetchUrl,
          file.path,
        );
      }

      if (await file.exists() && await file.length() > 0) {
        _settle(token, _CoverLoadResult(file: file));
        return;
      }

      final _CoverLoadResult cached;
      final existing = _inFlight[fetchUrl];
      if (existing != null) {
        cached = await existing;
      } else {
        final future = _downloadAndCache(fetchUrl, file);
        _inFlight[fetchUrl] = future;
        try {
          cached = await future;
        } finally {
          _inFlight.remove(fetchUrl);
        }
      }
      if (cacheOwner != null && cached.file != null) {
        await AppDatabase.registerCoverCache(
          cacheOwner,
          fetchUrl,
          cached.file!.path,
        );
      }
      _settle(token, cached);
    } catch (_) {
      _settle(token, const _CoverLoadResult());
    }
  }

  /// Downloads [fetchUrl] into [file] via a `.part` sibling + rename, so a
  /// kill mid-write can never leave a truncated file cached forever.
  static Future<_CoverLoadResult> _downloadAndCache(String fetchUrl, File file) async {
    try {
      final req = await _client.getUrl(Uri.parse(fetchUrl));
      final host = req.uri.host;
      req.headers.set(
        'Referer',
        host.contains('music.126.net') || host.contains('music.163.com')
            ? 'https://music.163.com/'
            : host.contains('y.gtimg.cn')
                ? 'https://y.qq.com/'
                : 'https://www.bilibili.com/',
      );
      req.headers.set('User-Agent', kBiliUserAgent);
      final res = await req.close();

      if (res.statusCode != 200) {
        final statusCode = res.statusCode;
        await res.drain<void>();
        return _CoverLoadResult(statusCode: statusCode);
      }

      final part = File('${file.path}.part');
      try {
        final sink = part.openWrite();
        try {
          await res.pipe(sink);
        } finally {
          await sink.close();
        }
        if (await part.length() == 0) {
          return const _CoverLoadResult();
        }
        await part.rename(file.path);
        return _CoverLoadResult(file: file);
      } finally {
        // A failed download must not leave a `.part` file in temp forever.
        if (await part.exists()) {
          try {
            await part.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      return const _CoverLoadResult();
    }
  }

  @override
  Widget build(BuildContext context) {
    final dpr = MediaQuery.of(context).devicePixelRatio;
    // Decode headroom: [ResizeImagePolicy.fit] fits the image *inside* the
    // box, but `BoxFit.cover` then scales by the box's *larger* ratio. Sizing
    // the decode box up by the widest cover we expect (16:9) keeps a landscape
    // image sharp when it is cropped to a square. It costs nothing for the
    // usual case: ResizeImage never upscales, so the decode is still capped at
    // the source, and CDN thumbnails already arrive at the requested square.
    const headroom = 16 / 9;
    final cacheW = (widget.width * dpr * headroom).round();
    final cacheH = (widget.height * dpr * headroom).round();

    late final Widget child;
    switch (_status) {
      case _CoverStatus.deferred:
        child = _buildDeferredPlaceholder();
      case _CoverStatus.ready:
        child = Image(
          // Not `Image.file(cacheWidth:, cacheHeight:)`: passing both forces
          // an exact-size decode, which *stretches* anything whose aspect
          // ratio is not the box's. Bilibili's CDN hands back a square crop so
          // list thumbnails looked right, but a custom cover picked from disk
          // (or any URL the CDN does not resize) was squashed into the square
          // album art on the player page. `fit` preserves the aspect ratio and
          // lets [BoxFit.cover] do the cropping, as it does everywhere else.
          image: ResizeImage(
            FileImage(_file!),
            width: cacheW > 0 ? cacheW : null,
            height: cacheH > 0 ? cacheH : null,
            policy: ResizeImagePolicy.fit,
          ),
          key: ValueKey(_file!.path),
          width: widget.width,
          height: widget.height,
          fit: widget.fit,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) => _buildFallback(),
        );
      case _CoverStatus.failed:
        child = _buildFallback();
      case _CoverStatus.loading:
        child = _buildLoadingPlaceholder();
    }

    return AnimatedSwitcher(
      duration: AppMotion.fast,
      switchInCurve: AppMotion.standard,
      child: SizedBox(
        key: ValueKey(_status),
        width: widget.width,
        height: widget.height,
        child: child,
      ),
    );
  }

  Widget _buildDeferredPlaceholder() {
    return Container(
      key: const Key('coverDeferredPlaceholder'),
      width: widget.width,
      height: widget.height,
      color: context.palette.surfaceDeep,
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: context.palette.textFaint,
          size: (widget.width * 0.28).clamp(14.0, 40.0),
        ),
      ),
    );
  }

  Widget _buildLoadingPlaceholder() {
    return Container(
      key: const Key('coverLoadingPlaceholder'),
      width: widget.width,
      height: widget.height,
      color: context.palette.surfaceDeep,
      child: Center(
        child: SizedBox.square(
          dimension: (widget.width * 0.28).clamp(14.0, 34.0),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: context.palette.accent,
          ),
        ),
      ),
    );
  }

  Widget _buildFallback() {
    if (_httpStatus != null) {
      return Container(
        key: const Key('coverHttpError'),
        width: widget.width,
        height: widget.height,
        color: context.palette.surfaceDeep,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HugeIcon(
                icon: HugeIcons.strokeRoundedGlobeOff,
                color: context.palette.textMuted,
                size: (widget.width * 0.34).clamp(18.0, 44.0),
              ),
              const SizedBox(height: 2),
              Text(
                '$_httpStatus',
                style: TextStyle(
                  color: context.palette.textMuted,
                  fontSize: (widget.width * 0.16).clamp(9.0, 13.0),
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      );
    }
    return Container(
      key: const Key('coverFallback'),
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            context.palette.accent.withValues(alpha: 0.22),
            context.palette.surfaceDeep,
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.music_note_rounded,
          color: context.palette.accent,
          size: (widget.width * 0.4).clamp(24.0, 80.0),
        ),
      ),
    );
  }
}
