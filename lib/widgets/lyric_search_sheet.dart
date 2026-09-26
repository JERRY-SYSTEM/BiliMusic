import 'package:flutter/material.dart';

import 'package:hugeicons/hugeicons.dart';
import '../models/lyric_line.dart';
import '../models/track.dart';
import '../services/lyrics_engine.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'cached_cover_image.dart';

Future<void> showLyricSearchSheet({
  required BuildContext context,
  required String initialKeyword,
  required Track track,
  required Future<void> Function(LyricsResult result, LyricApplySelection selection) onApply,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.palette.backgroundElevated,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _LyricSearchSheet(
      initialKeyword: initialKeyword,
      track: track,
      onApply: onApply,
    ),
  );
}

class _LyricSearchSheet extends StatefulWidget {
  const _LyricSearchSheet({
    required this.initialKeyword,
    required this.track,
    required this.onApply,
  });

  final String initialKeyword;
  final Track track;
  final Future<void> Function(LyricsResult result, LyricApplySelection selection) onApply;

  @override
  State<_LyricSearchSheet> createState() => _LyricSearchSheetState();
}

class _LyricSearchSheetState extends State<_LyricSearchSheet> {
  late final TextEditingController _controller;
  LyricProvider _provider = LyricProvider.netease;
  List<LyricSearchCandidate> _results = const [];
  bool _searching = false;
  String? _loadingId;
  String? _error;
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialKeyword);
    WidgetsBinding.instance.addPostFrameCallback((_) => _search());
  }

  @override
  void dispose() {
    _generation++;
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final keyword = _controller.text.trim();
    if (keyword.isEmpty) {
      setState(() {
        _results = const [];
        _error = null;
      });
      return;
    }
    final generation = ++_generation;
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await LyricsEngine.searchCandidates(
        keyword,
        provider: _provider,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = results;
        _searching = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _results = const [];
        _searching = false;
        _error = '搜索失败：$error';
      });
    }
  }

  Future<void> _apply(LyricSearchCandidate candidate) async {
    Haptics.selection();
    setState(() {
      _loadingId = candidate.id;
      _error = null;
    });
    try {
      final result = await LyricsEngine.fetchCandidateLyrics(candidate);
      if (!mounted) return;
      if (result == null || result.lines.isEmpty) {
        setState(() {
          _loadingId = null;
          _error = '该条目没有可用的同步歌词';
        });
        return;
      }
      final selection = await showDialog<LyricApplySelection>(
        context: context,
        builder: (_) => const _LyricApplyDialog(),
      );
      if (selection == null || !mounted) {
        if (mounted) setState(() => _loadingId = null);
        return;
      }
      await widget.onApply(result, selection);
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _loadingId = null;
        _error = '应用失败：$error';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(16, 16, 16, keyboard + 16),
        child: SizedBox(
          height: 440,
          child: Column(
            children: [
              TextField(
                      key: const Key('manualLyricSearchField'),
                      controller: _controller,
                      enabled: _loadingId == null,
                      textInputAction: TextInputAction.search,
                      onSubmitted: (_) => _search(),
                      decoration: InputDecoration(
                        hintText: '搜索歌词',
                        prefixIcon: const SizedBox(
                          width: 48,
                          child: Center(
                            child: HugeIcon(
                              icon: HugeIcons.strokeRoundedMusic3,
                              size: 16,
                            ),
                          ),
                        ),
                        filled: true,
                        fillColor: context.palette.surfaceDeep,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(14),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<LyricProvider>(
                    key: const Key('lyricProviderSelector'),
                    initialValue: _provider,
                    decoration: InputDecoration(
                      labelText: '音乐源',
                      filled: true,
                      fillColor: context.palette.surfaceDeep,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    items: LyricProvider.values
                        .map(
                          (provider) => DropdownMenuItem(
                            value: provider,
                            child: Text(provider.label),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: _loadingId != null || _searching
                        ? null
                        : (provider) {
                            if (provider == null || provider == _provider) return;
                            setState(() => _provider = provider);
                            _search();
                          },
                    ),
                  ),
                  const SizedBox(width: 10),
                  IconButton.filled(
                    key: const Key('lyricSearchSubmitButton'),
                    tooltip: '搜索',
                    onPressed: _loadingId != null || _searching ? null : _search,
                    icon: const HugeIcon(icon: HugeIcons.strokeRoundedSearch01),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    _error!,
                    style: TextStyle(color: context.palette.danger),
                    textAlign: TextAlign.center,
                  ),
                ),
              Expanded(child: _resultList()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _resultList() {
    if (_searching && _results.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: context.palette.accent),
      );
    }
    if (_results.isEmpty) {
      return Center(
        child: Text(
          '没有搜索到结果',
          style: TextStyle(color: context.palette.textMuted),
        ),
      );
    }
    return ListView.separated(
      itemCount: _results.length,
      separatorBuilder: (context, index) => Divider(color: context.palette.hairline),
      itemBuilder: (context, index) {
        final item = _results[index];
        final loading = _loadingId == item.id;
        return ListTile(
          key: ValueKey('lyricResult-${item.provider.apiName}-${item.id}'),
          leading: Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: context.palette.accent12,
              borderRadius: BorderRadius.circular(8),
            ),
            child: (item.pictureUrl ?? '').isNotEmpty
                    ? ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: CachedCoverImage(
                          url: item.pictureUrl!,
                          track: widget.track,
                          width: 44,
                          height: 44,
                        ),
                      )
                    : Icon(Icons.music_note_rounded,
                        color: context.palette.accent),
          ),
          title: Text(
            item.title.trim().isEmpty ? '未知歌曲' : item.title.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            item.artist.trim().isEmpty ? '未知歌手' : item.artist.trim(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: loading
              ? SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.palette.accent,
                  ),
                )
              : null,
          onTap: _loadingId == null && !_searching ? () => _apply(item) : null,
        );
      },
    );
  }
}

class LyricApplySelection {
  const LyricApplySelection({
    required this.title,
    required this.artist,
    required this.cover,
  });

  final bool title;
  final bool artist;
  final bool cover;
}

class _LyricApplyDialog extends StatefulWidget {
  const _LyricApplyDialog();

  @override
  State<_LyricApplyDialog> createState() => _LyricApplyDialogState();
}

class _LyricApplyDialogState extends State<_LyricApplyDialog> {
  bool _title = false;
  bool _artist = false;
  bool _cover = true;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('选择要覆盖的内容'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CheckboxListTile(title: const Text('歌名'), value: _title, onChanged: (v) => setState(() => _title = v ?? false)),
          CheckboxListTile(title: const Text('作者'), value: _artist, onChanged: (v) => setState(() => _artist = v ?? false)),
          CheckboxListTile(title: const Text('封面'), value: _cover, onChanged: (v) => setState(() => _cover = v ?? false)),
          const CheckboxListTile(title: Text('歌词'), value: true, onChanged: null),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.pop(
            context,
            LyricApplySelection(title: _title, artist: _artist, cover: _cover),
          ),
          child: const Text('覆盖'),
        ),
      ],
    );
  }
}
