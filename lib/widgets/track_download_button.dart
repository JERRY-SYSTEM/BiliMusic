import 'dart:async';

import 'package:flutter/material.dart';

import '../models/track.dart';
import '../models/audio_quality.dart';
import '../services/app_settings_service.dart';
import '../services/bili_auth_service.dart';
import '../services/bilibili_sdk.dart';
import '../services/audio_download_service.dart';
import '../services/download_manager.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'progress_ring.dart';

/// A context-aware download/play button with an Apple Music–style progress
/// ring while downloading. Morphs: download → ring → play.
class TrackDownloadButton extends StatefulWidget {
  final Track track;
  final double size;

  /// Called when the track is already downloaded and the user taps play.
  final VoidCallback? onPlay;
  final bool isPlayNext;

  const TrackDownloadButton({
    super.key,
    required this.track,
    this.size = 26,
    this.onPlay,
    this.isPlayNext = false,
  });

  @override
  State<TrackDownloadButton> createState() => _TrackDownloadButtonState();
}

class _TrackDownloadButtonState extends State<TrackDownloadButton> {
  StreamSubscription<String>? _sub;
  bool _isDownloaded = false;
  bool _wasDownloading = false;
  double _fraction = 0.0;

  @override
  void initState() {
    super.initState();
    _refresh();
    // One targeted subscription per row. Events carry the changed track id,
    // so a row wakes only for its own track, and the manager's relay of
    // playback-path completions (see DownloadManager._onProgress) covers the
    // downloads that never pass through startDownload — previously this
    // needed a second, chunk-frequency subscription to the raw progress
    // stream on every row.
    _sub = DownloadManager.instance.updates.listen((changedId) {
      if (!mounted || changedId != widget.track.id) return;
      final task = DownloadManager.instance.taskFor(widget.track.id);
      final downloading = task != null;
      final fraction = task?.fraction ?? 0.0;
      if (downloading == _wasDownloading && fraction == _fraction) {
        // Same state — but an untracked (playback-path) download's
        // completion event is the only signal its file reached disk.
        if (!downloading && !_isDownloaded) _refresh();
        return;
      }
      if (_wasDownloading && !downloading) _refresh();
      _wasDownloading = downloading;
      _fraction = fraction;
      setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant TrackDownloadButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.track.id != widget.track.id) {
      // Reset synchronously: _refresh() is async and the old track's flag
      // would otherwise paint one stale frame.
      _isDownloaded = false;
      _wasDownloading = false;
      _fraction = 0.0;
      _refresh();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    // Rows recycle: by the time isDownloaded returns, this State may belong
    // to a different track (didUpdateWidget swapped it). Only commit the
    // result if the widget still shows the track we asked about.
    final trackId = widget.track.id;
    final downloaded = await AudioDownloadService.isDownloaded(widget.track, quality: widget.track.qualityId);
    if (mounted && widget.track.id == trackId) {
      setState(() => _isDownloaded = downloaded);
    }
  }

  /// One box, one glyph, one place.
  ///
  /// The three states used to be built from different widgets — an IconButton
  /// when idle (with its own 48pt minimum and padding) and a bare SizedBox
  /// while downloading — so the control jumped sideways the moment you tapped
  /// it, and the glyph changed from a download arrow to a different download
  /// arrow on the way. Same footprint, same glyph, always: starting a download
  /// only draws a ring around it, exactly as the player page's primary control
  /// does.
  static const double _box = 44.0;

  @override
  Widget build(BuildContext context) {
    final task = DownloadManager.instance.taskFor(widget.track.id);

    final Widget glyph;
    final VoidCallback? onTap;
    final String tooltip;
    if (task != null) {
      glyph = Icon(Icons.download_rounded,
          color: context.palette.textSecondary, size: widget.size);
      onTap = null;
      tooltip = '下载中';
    } else if (_isDownloaded) {
      glyph = Icon(
        widget.isPlayNext ? Icons.playlist_add_rounded : Icons.play_circle_fill,
        color: widget.isPlayNext ? context.palette.textSecondary : context.palette.accent,
        size: widget.isPlayNext ? widget.size : widget.size + 4,
      );
      onTap = () {
        Haptics.light();
        widget.onPlay?.call();
      };
      tooltip = widget.isPlayNext ? '下一首播放' : '播放';
    } else {
      glyph = Icon(Icons.download_rounded,
          color: context.palette.textSecondary, size: widget.size);
      onTap = () {
        Haptics.light();
        _chooseQualityAndDownload();
      };
      tooltip = '下载';
    }

    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(
          width: _box,
          height: _box,
          child: Center(
            child: task == null
                ? glyph
                : ProgressRing(
                    fraction: task.fraction,
                    size: widget.size + 12,
                    child: glyph,
                  ),
          ),
        ),
      ),
    );
  }

  Future<void> _chooseQualityAndDownload() async {
    final session = BiliAuthController.instance.session;
    List<AudioQualityOption> options;
    try {
      options = await BilibiliSdk.fetchAudioQualities(widget.track.bvid, widget.track.cid,
          cookies: session?.cookie, preferredQuality: AppSettingsService.instance.defaultAudioQuality);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('获取音质失败：$e')));
      return;
    }
    if (!mounted || options.isEmpty) return;
    final selected = await showModalBottomSheet<AudioQualityOption>(
      context: context,
      builder: (context) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('选择音质'), subtitle: Text('下载后将按音质分别缓存')),
        ...options.map((option) => ListTile(
          title: Text(option.label), subtitle: Text(option.bandwidth > 0 ? '${option.bandwidth ~/ 1000} kbps' : ''),
          trailing: option.id == AppSettingsService.instance.defaultAudioQuality ? const Icon(Icons.check) : null,
          onTap: () => Navigator.pop(context, option),
        )),
      ])),
    );
    if (selected != null) {
      await AppSettingsService.instance.setDefaultAudioQuality(selected.id ?? 0);
      await DownloadManager.instance.startDownload(widget.track, quality: selected);
    }
  }
}
