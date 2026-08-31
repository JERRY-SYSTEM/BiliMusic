import 'package:flutter/material.dart';

import 'package:hugeicons/hugeicons.dart';
import '../models/bili_favorite_collection.dart';
import '../models/bili_session.dart';
import '../models/track.dart';
import '../services/bili_favorites_service.dart';

class ImportDestination {
  const ImportDestination.newPlaylist(this.name) : existingId = null;
  const ImportDestination.existing(this.existingId) : name = null;
  final String? name;
  final String? existingId;
}

class FavoritePickerDialog extends StatefulWidget {
  const FavoritePickerDialog({super.key, required this.session});
  final BiliSession session;

  @override
  State<FavoritePickerDialog> createState() => _FavoritePickerDialogState();
}

class _FavoritePickerDialogState extends State<FavoritePickerDialog> {
  late final Future<List<BiliFavoriteCollection>> _future = BiliFavoritesService.fetchCollections(widget.session);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('导入收藏夹'),
        content: SizedBox(
          width: 360,
          child: FutureBuilder<List<BiliFavoriteCollection>>(
            future: _future,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
              if (snapshot.hasError) return SizedBox(height: 120, child: Center(child: Text('获取收藏夹失败：${snapshot.error}')));
              final collections = snapshot.data ?? const <BiliFavoriteCollection>[];
              if (collections.isEmpty) return const SizedBox(height: 120, child: Center(child: Text('没有可导入的收藏夹')));
              return ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: collections.length,
                  separatorBuilder: (context, index) => const Divider(height: 1),
                  itemBuilder: (_, index) {
                    final item = collections[index];
                    return ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const HugeIcon(icon: HugeIcons.strokeRoundedPlaylist01),
                      title: Text(item.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                      subtitle: Text('${item.itemCount} 个内容'),
                      onTap: () => Navigator.pop(context, item),
                    );
                  },
                ),
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消'))],
      );
}

class FavoriteTracksDialog extends StatefulWidget {
  const FavoriteTracksDialog({super.key, required this.session, required this.collection});
  final BiliSession session;
  final BiliFavoriteCollection collection;

  @override
  State<FavoriteTracksDialog> createState() => _FavoriteTracksDialogState();
}

class _FavoriteTracksDialogState extends State<FavoriteTracksDialog> {
  late final Future<List<Track>> _future = BiliFavoritesService.fetchTracks(widget.session, widget.collection.id);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text('读取「${widget.collection.name}」'),
        content: FutureBuilder<List<Track>>(
          future: _future,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) return const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()));
            if (snapshot.hasError) return SizedBox(height: 120, child: Center(child: Text('读取失败：${snapshot.error}')));
            final tracks = snapshot.data ?? const <Track>[];
            return Column(mainAxisSize: MainAxisSize.min, children: [
              Text(tracks.isEmpty ? '收藏夹中没有可导入的视频' : '已找到 ${tracks.length} 首可导入曲目'),
              const SizedBox(height: 16),
              if (tracks.isNotEmpty) SizedBox(height: 180, width: 340, child: ListView.builder(itemCount: tracks.length, itemBuilder: (_, i) => ListTile(dense: true, title: Text(tracks[i].title, maxLines: 1, overflow: TextOverflow.ellipsis), subtitle: Text(tracks[i].uploader)))),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')), FilledButton(onPressed: tracks.isEmpty ? null : () => Navigator.pop(context, tracks), child: const Text('继续'))]),
            ]);
          },
        ),
      );
}
