import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../services/database_service.dart';

class CacheSettingsPage extends StatefulWidget {
  const CacheSettingsPage({super.key});
  @override State<CacheSettingsPage> createState() => _CacheSettingsPageState();
}
class _CacheSettingsPageState extends State<CacheSettingsPage> {
  int _bytes = 0; bool _busy = false;
  @override void initState() { super.initState(); _reload(); }
  Future<void> _reload() async {
    final dir = await getApplicationDocumentsDirectory();
    var total = 0;
    for (final entity in Directory(dir.path).listSync(recursive: true)) {
      if (entity is File && (entity.path.contains('bilibeat_audio') || entity.path.contains('bilibeat_lyrics') || entity.path.contains('bilibeat_'))) total += entity.lengthSync();
    }
    if (mounted) setState(() => _bytes = total);
  }
  Future<void> _clear() async {
    if (_busy) return;
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('清理全部缓存？'), content: const Text('将删除图片、歌词、元信息和已下载音频，歌单中的本地音频也会被移除。'),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('取消')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('确认'))],
    )) ?? false;
    if (!ok) return;
    setState(() => _busy = true);
    final tracks = await DatabaseService.getDownloadedTracks();
    for (final track in tracks) { await DatabaseService.removeDownloadedTrack(track); }
    final dir = await getApplicationDocumentsDirectory();
    for (final entity in Directory(dir.path).listSync(recursive: true)) {
      if (entity is File && (entity.path.endsWith('.part') || entity.path.contains('bilibeat_audio'))) { try { await entity.delete(); } catch (_) {} }
    }
    final lyrics = File('${dir.path}/bilibeat_lyrics.json');
    if (await lyrics.exists()) await lyrics.delete();
    final support = await getApplicationSupportDirectory();
    final covers = Directory('${support.path}/bilibeat_covers');
    if (await covers.exists()) await covers.delete(recursive: true);
    await _reload();
    if (mounted) setState(() => _busy = false);
  }
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('缓存管理')),
    body: Padding(padding: const EdgeInsets.all(20), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('当前缓存约 ${( _bytes / 1024 / 1024).toStringAsFixed(1)} MB'), const SizedBox(height: 24),
      FilledButton.icon(onPressed: _busy ? null : _clear, icon: const Icon(Icons.delete_sweep_outlined), label: Text(_busy ? '清理中…' : '清理全部缓存')),
    ])),
  );
}
