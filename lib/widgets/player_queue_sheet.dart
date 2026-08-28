import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import '../models/track.dart';
import '../services/audio_player_handler.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'cached_cover_image.dart';

  Future<void> showPlayerQueueSheet({
    required BuildContext context,
    required BiliBeatAudioHandler handler,
    VoidCallback? onQueueCleared,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: context.palette.backgroundElevated,
    builder: (_) => SafeArea(
      child: PlayerQueueSheet(
        handler: handler,
        onQueueCleared: onQueueCleared,
      ),
    ),
  );
}

class PlayerQueueSheet extends StatelessWidget {
  const PlayerQueueSheet({
    super.key,
    required this.handler,
    this.onQueueCleared,
  });

  final BiliBeatAudioHandler handler;
  final VoidCallback? onQueueCleared;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<PlaybackQueueState>(
      stream: handler.queueStream,
      initialData: PlaybackQueueState(
        queue: handler.playbackQueue,
        currentIndex: handler.currentQueueIndex,
      ),
      builder: (context, snapshot) {
        final state = snapshot.data!;
        final mode = handler.isShuffle
            ? '随机播放'
            : handler.loopMode == LoopMode.one
                ? '单曲循环'
                : handler.loopMode == LoopMode.off
                    ? '顺序播放'
                    : '列表循环';
        return SizedBox(
          height: MediaQuery.sizeOf(context).height * .72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 16, 14),
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('播放列表', style: AppTypography.title.copyWith(color: context.palette.textPrimary)),
                          const SizedBox(height: 4),
                          Text('${state.queue.length} 首 · $mode',
                              style: AppTypography.bodyMedium.copyWith(
                                  color: context.palette.textSecondary)),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '播放模式',
                      onPressed: state.queue.isEmpty
                          ? null
                          : () {
                              Haptics.medium();
                              handler.cyclePlayMode();
                            },
                      icon: HugeIcon(
                        icon: handler.isShuffle
                            ? HugeIcons.strokeRoundedShuffle
                            : handler.loopMode == LoopMode.one
                                ? HugeIcons.strokeRoundedRepeatOne01
                                : HugeIcons.strokeRoundedRepeat,
                        color: context.palette.textSecondary,
                      ),
                    ),
                    IconButton(
                      tooltip: '清空播放列表',
                      onPressed: state.queue.isEmpty
                          ? null
                          : () async {
                              Haptics.medium();
                              final confirmed = await showDialog<bool>(
                                context: context,
                                builder: (dialogContext) => AlertDialog(
                                  title: const Text('清空播放列表'),
                                  content: const Text('将清空所有曲目并停止当前播放，确定继续吗？'),
                                  actions: [
                                    TextButton(
                                      onPressed: () => Navigator.pop(dialogContext, false),
                                      child: const Text('取消'),
                                    ),
                                    FilledButton(
                                      onPressed: () => Navigator.pop(dialogContext, true),
                                      child: const Text('清空'),
                                    ),
                                  ],
                                ),
                              );
                              if (confirmed == true) {
                                await handler.clearQueue();
                                onQueueCleared?.call();
                              }
                            },
                      icon: Icon(Icons.delete_sweep_rounded,
                          color: context.palette.textSecondary),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: state.queue.isEmpty
                    ? Center(
                        child: Text('暂无播放曲目',
                            style: TextStyle(color: context.palette.textSecondary)),
                      )
                    : ReorderableListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                        buildDefaultDragHandles: false,
                        itemCount: state.queue.length,
                        onReorderItem: handler.reorderQueueItem,
                        itemBuilder: (context, index) {
                          final track = state.queue[index];
                          final current = index == state.currentIndex;
                          return _QueueRow(
                            key: ValueKey(track.id),
                            track: track,
                            index: index,
                            current: current,
                            onTap: () async {
                              await handler.skipToQueueItem(index);
                              if (context.mounted) Navigator.pop(context);
                            },
                            onRemove: () => handler.removeQueueItemAt(index),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _QueueRow extends StatelessWidget {
  const _QueueRow({
    super.key,
    required this.track,
    required this.index,
    required this.current,
    required this.onTap,
    required this.onRemove,
  });

  final Track track;
  final int index;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: current ? context.palette.accentSoft : context.palette.surfaceCard,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadius.md),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: CachedCoverImage(url: track.coverUrl, width: 44, height: 44),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(track.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.headline.copyWith(
                              color: context.palette.textPrimary)),
                      const SizedBox(height: 3),
                      Text(track.uploader,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTypography.caption.copyWith(
                              color: context.palette.textMuted)),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '移出队列',
                  onPressed: onRemove,
                  icon: const Icon(Icons.close_rounded, size: 19),
                ),
                ReorderableDragStartListener(
                  index: index,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.drag_handle_rounded, size: 20),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
