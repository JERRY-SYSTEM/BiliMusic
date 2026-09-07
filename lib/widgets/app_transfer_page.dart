import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hugeicons/hugeicons.dart';

import '../services/app_transfer_service.dart';
import '../theme/app_theme.dart';

class AppTransferPage extends StatefulWidget {
  const AppTransferPage({super.key});

  @override
  State<AppTransferPage> createState() => _AppTransferPageState();
}

class _AppTransferPageState extends State<AppTransferPage> {
  final AppTransferService _service = const AppTransferService();
  bool _exporting = false;
  bool _importing = false;

  bool get _busy => _exporting || _importing;

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('数据导入导出')),
        body: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: context.palette.accent.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.security_outlined),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      '备份可包含 B 站登录 Cookie，拥有备份文件的人可能访问你的账号。请勿将文件发送给他人。',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  ListTile(
                    leading: const HugeIcon(icon: HugeIcons.strokeRoundedDatabaseExport),
                    title: const Text('导出数据'),
                    subtitle: const Text('备份登录信息、收藏、歌单与本地自定义'),
                    trailing: _exporting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: _busy ? null : _exportData,
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const HugeIcon(icon: HugeIcons.strokeRoundedDatabaseImport),
                    title: const Text('导入数据'),
                    subtitle: const Text('预览备份内容并选择要恢复的项目'),
                    trailing: _importing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.chevron_right_rounded),
                    onTap: _busy ? null : _importData,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '不会备份音频、封面、联网元信息、普通歌词缓存、播放记录、外观或音质设置。导入歌单时需联网重新获取歌曲信息。',
              style: TextStyle(color: context.palette.textMuted),
            ),
          ],
        ),
      );

  Future<void> _exportData() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('导出本地备份'),
        content: const Text(
          '备份中可能包含完整登录 Cookie。请将文件保存在安全位置，不要分享给他人。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('继续导出'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _exporting = true);
    try {
      final json = await _service.buildExportJson();
      final bytes = Uint8List.fromList(utf8.encode(json));
      final path = await FilePicker.saveFile(
        dialogTitle: '保存 BiliBeat 备份',
        fileName: _exportFileName(),
        type: FileType.custom,
        allowedExtensions: const ['json'],
        mimeType: 'application/json',
        bytes: bytes,
      );
      if (!mounted || path == null) return;
      _showMessage('备份已导出：$path');
    } catch (error) {
      if (mounted) _showMessage('导出失败：$error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _importData() async {
    setState(() => _importing = true);
    try {
      final result = await FilePicker.pickFiles(
        dialogTitle: '选择 BiliBeat 备份',
        type: FileType.custom,
        allowedExtensions: const ['json'],
        allowMultiple: false,
      );
      if (result.isEmpty) return;
      final file = result.first;
      final bytes = await file.readAsBytes();
      final preview = _service.previewImport(bytes);
      if (!mounted) return;
      final selection = await showDialog<AppImportSelection>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _ImportPreviewDialog(preview: preview),
      );
      if (selection == null || !mounted) return;
      if (selection.importSession) {
        final replaceSession = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('替换当前登录信息'),
            content: const Text(
              '导入 Cookie 会替换当前 B 站账号的登录状态。确定继续吗？',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('替换并导入'),
              ),
            ],
          ),
        );
        if (replaceSession != true || !mounted) return;
      }
      final importResult = await _service.importBytes(
        bytes: bytes,
        selection: selection,
      );
      if (!mounted) return;
      _showMessage(
        '导入完成：${importResult.playlistCount} 个歌单、'
        '${importResult.trackCount} 首歌曲'
        '${importResult.skippedTrackCount > 0 ? '，跳过 ${importResult.skippedTrackCount} 首' : ''}'
        '${importResult.failedOnlinePlaylistCount > 0 ? '，${importResult.failedOnlinePlaylistCount} 个在线歌单需稍后重试同步' : ''}',
      );
    } catch (error) {
      if (mounted) _showMessage('导入失败：$error');
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  String _exportFileName() {
    final now = DateTime.now();
    String two(int value) => value.toString().padLeft(2, '0');
    return 'bilibeat-backup-${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}.json';
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

class _ImportPreviewDialog extends StatefulWidget {
  const _ImportPreviewDialog({required this.preview});

  final AppImportPreview preview;

  @override
  State<_ImportPreviewDialog> createState() => _ImportPreviewDialogState();
}

class _ImportPreviewDialogState extends State<_ImportPreviewDialog> {
  late bool _session;
  late bool _favorites;
  late Set<String> _playlistIds;

  @override
  void initState() {
    super.initState();
    _session = widget.preview.hasSession;
    _favorites = widget.preview.favoriteTrackCount > 0;
    _playlistIds = widget.preview.playlists.map((item) => item.id).toSet();
  }

  bool get _canSubmit =>
      _session || _favorites || _playlistIds.isNotEmpty;

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('选择导入内容'),
        content: SizedBox(
          width: 440,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '备份包含收藏 ${widget.preview.favoriteTrackCount} 首、'
                  '本地歌单 ${widget.preview.localPlaylistCount} 个、'
                  '在线歌单 ${widget.preview.onlinePlaylistCount} 个。',
                ),
                const SizedBox(height: 8),
                if (widget.preview.hasSession)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _session,
                    title: const Text('登录信息'),
                    subtitle: const Text('包含登录 Cookie，不显示具体内容'),
                    onChanged: (value) =>
                        setState(() => _session = value ?? false),
                  ),
                if (widget.preview.favoriteTrackCount > 0)
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    value: _favorites,
                    title: const Text('收藏'),
                    subtitle:
                        Text('${widget.preview.favoriteTrackCount} 首歌曲'),
                    onChanged: (value) =>
                        setState(() => _favorites = value ?? false),
                  ),
                if (widget.preview.playlists.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text('歌单', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  ...widget.preview.playlists.map(
                    (playlist) => CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _playlistIds.contains(playlist.id),
                      title: Text(playlist.name),
                      subtitle: Text(
                        '${playlist.isOnline ? '在线歌单' : '本地歌单'} · ${playlist.trackCount} 首',
                      ),
                      onChanged: (value) => setState(() {
                        if (value == true) {
                          _playlistIds.add(playlist.id);
                        } else {
                          _playlistIds.remove(playlist.id);
                        }
                      }),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                Text(
                  '歌曲信息将通过网络恢复；无法恢复的单曲会被跳过。',
                  style: TextStyle(color: context.palette.textMuted),
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _canSubmit
                ? () => Navigator.pop(
                      context,
                      AppImportSelection(
                        importSession: _session,
                        importFavorites: _favorites,
                        playlistIds: _playlistIds,
                      ),
                    )
                : null,
            child: const Text('开始导入'),
          ),
        ],
      );
}
