import 'dart:io';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';
import '../services/audio_download_service.dart';
import '../services/cache_inventory.dart';
import '../services/database_service.dart';
import '../theme/app_theme.dart';
import 'cached_cover_image.dart';

class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key});
  @override State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}

class _CacheSettingsPageState extends State<CacheSettingsPage> {
  List<CacheBucket> _buckets = const [];
  final Set<String> _selected = <String>{};
  bool _loading = true;
  bool _busy = false;

  @override void initState() { super.initState(); _reload(); }
  Future<void> _reload() async {
    final buckets = await CacheInventory.load(await DatabaseService.getDownloadedTracks());
    if (mounted) setState(() { _buckets = buckets; _loading = false; });
  }
  int get _total => _buckets.fold(0, (sum, bucket) => sum + bucket.bytes);
  int get _selectedBytes => _buckets.where((b) => _selected.contains(b.track?.id ?? '__other__')).fold(0, (sum, b) => sum + b.bytes);

  Future<void> _deleteSelected() async {
    if (_busy || _selectedBytes == 0) return;
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('删除所选缓存？'),
      content: Text('将删除 ${_selected.length} 个缓存项目，共约 ${_formatBytes(_selectedBytes)}。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('删除'))],
    )) ?? false;
    if (!ok) return;
    setState(() => _busy = true);
    for (final bucket in _buckets.where((b) => _selected.contains(b.track?.id ?? '__other__'))) {
      if (bucket.track != null) {
        await AudioDownloadService.deleteAllForTrack(bucket.track!);
        await DatabaseService.removeCachedLyrics(bucket.track!.id);
        await DatabaseService.removeDownloadedTrack(bucket.track!);
      }
      for (final file in [...bucket.files, ...bucket.coverFiles]) { try { await file.delete(); } catch (_) {} }
    }
    _selected.clear();
    await _reload();
    if (mounted) setState(() => _busy = false);
  }

  void _toggleAll() => setState(() {
    final keys = _buckets.map((b) => b.track?.id ?? '__other__').toSet();
    if (_selected.length == keys.length) { _selected.clear(); } else { _selected..clear()..addAll(keys); }
  });

  @override Widget build(BuildContext context) {
    final palette = context.palette;
    return Scaffold(
      appBar: AppBar(title: const Text('缓存管理'), actions: [IconButton(onPressed: _loading ? null : _toggleAll, tooltip: '全选/取消全选', icon: const HugeIcon(icon: HugeIcons.strokeRoundedMore03))]),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      Text('缓存总量 ${_formatBytes(_total)}', style: TextStyle(color: palette.textSecondary)),
                      const SizedBox(height: 12),
                      if (_buckets.isEmpty)
                        Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(child: Text('暂无缓存', style: TextStyle(color: palette.textSecondary))),
                        )
                      else
                        ..._buckets.map(_bucketTile),
                    ],
                  ),
                ),
                SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _busy || _selectedBytes == 0 ? null : _deleteSelected,
                      icon: const HugeIcon(icon: HugeIcons.strokeRoundedDelete02),
                      label: Text(_busy ? '删除中…' : '删除所选缓存 ${_formatBytes(_selectedBytes)}'),
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _bucketTile(CacheBucket bucket) {
    final key = bucket.track?.id ?? '__other__';
    final track = bucket.track;
    return CheckboxListTile(
      value: _selected.contains(key),
      onChanged: _busy ? null : (value) => setState(() => value == true ? _selected.add(key) : _selected.remove(key)),
      secondary: track == null ? HugeIcon(icon: HugeIcons.strokeRoundedFolderUnknown, color: context.palette.accent) : (track.coverUrl.isEmpty ? HugeIcon(icon: HugeIcons.strokeRoundedHeadphones, color: context.palette.accent) : ClipRRect(borderRadius: BorderRadius.circular(AppRadius.sm), child: CachedCoverImage(url: track.coverUrl, width: 48, height: 48))),
      title: Text(track?.title ?? '其它', maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(track == null ? '无法关联到具体歌曲的缓存' : '${track.uploader} · ${_formatBytes(bucket.bytes)}', maxLines: 1, overflow: TextOverflow.ellipsis),
      controlAffinity: ListTileControlAffinity.trailing,
    );
  }
}

String _formatBytes(int bytes) => bytes < 1024 * 1024 ? '${(bytes / 1024).toStringAsFixed(1)} KB' : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
