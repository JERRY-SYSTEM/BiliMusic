import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../services/lyrics_engine.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'lyric_editor_info_tab.dart';

class LyricEditorDialog extends StatefulWidget {
  final String songTitle;
  /// The B站 raw video title. 智能识别 must parse this, never [songTitle]:
  /// metadata edits overwrite [songTitle] but the parse has to stay
  /// deterministic against the original title.
  final String rawTitle;
  final String artistName;
  final String? coverUrl;
  final Future<void> Function(
    String title,
    String artist,
    String coverUrl,
  )? onUpdateMetadata;

  const LyricEditorDialog({
    super.key,
    required this.songTitle,
    required this.rawTitle,
    required this.artistName,
    this.coverUrl,
    this.onUpdateMetadata,
  });

  @override
  State<LyricEditorDialog> createState() => _LyricEditorDialogState();
}

class _LyricEditorDialogState extends State<LyricEditorDialog> {
  late TextEditingController _titleController;
  late TextEditingController _artistController;
  late TextEditingController _coverUrlController;

  /// Monotonic guard for 智能识别: only the LAST tap's validated result may
  /// write the fields, no matter which of several in-flight parses completes.
  int _parseToken = 0;

  /// True while a 智能识别 validation lookup is in flight. The button shows a
  /// spinner instead of guessing into the fields.
  bool _parsing = false;
  bool _saving = false;
  String? _saveError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.songTitle);
    _artistController = TextEditingController(text: widget.artistName);
    _coverUrlController = TextEditingController(text: widget.coverUrl ?? '');
  }

  @override
  void dispose() {
    _titleController.dispose();
    _artistController.dispose();
    _coverUrlController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Cover picker
  // ---------------------------------------------------------------------------

  Future<void> _pickLocalCoverImage() async {
    try {
      final picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      if (image != null) {
        final docs = await getApplicationDocumentsDirectory();
        final coversDir = Directory('${docs.path}/bilimusic_covers');
        if (!await coversDir.exists()) {
          await coversDir.create(recursive: true);
        }
        final ext = image.path.split('.').last;
        final savedFile = File(
            '${coversDir.path}/cover_${DateTime.now().millisecondsSinceEpoch}.$ext');
        await File(image.path).copy(savedFile.path);

        if (mounted) {
          setState(() => _coverUrlController.text = savedFile.path);
        }
      }
    } catch (e) {
      debugPrint('Error picking cover image: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Metadata
  // ---------------------------------------------------------------------------

  Future<void> _saveAll() async {
    if (_saving) return;
    final newTitle = _titleController.text.trim();
    final newArtist = _artistController.text.trim();
    final newCover = _coverUrlController.text.trim();

    final hasMetadataEdit = newTitle.isNotEmpty &&
        (newTitle != widget.songTitle ||
         newArtist != widget.artistName ||
         newCover != (widget.coverUrl ?? ''));

    if (!hasMetadataEdit || widget.onUpdateMetadata == null) {
      _close();
      return;
    }

    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await widget.onUpdateMetadata!(
        newTitle,
        newArtist.isNotEmpty ? newArtist : '未知UP主',
        newCover,
      );
      if (mounted) _close();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _saveError = '保存失败：$error';
      });
    }
  }
  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  void _close() {
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Expanded(
            child: _buildInfoTab(),
          ),
          const SizedBox(height: 12),
          if (_saveError != null) ...[
            Text(
              _saveError!,
              key: const Key('metadataSaveError'),
              style: TextStyle(color: context.palette.danger),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
          ],
          // Stationary actions fixed at the bottom of the dialog.
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: ElevatedButton(
                    key: const Key('metadataSaveButton'),
                    onPressed: _saving ? null : _saveAll,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: context.palette.accent,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: _saving
                        ? SizedBox.square(
                            key: const Key('metadataSavingIndicator'),
                            dimension: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: context.palette.textPrimary,
                            ),
                          )
                        : Text('确认',
                            style: TextStyle(
                                color: context.palette.textPrimary,
                                fontWeight: FontWeight.bold,
                                fontSize: 15)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SizedBox(
                  height: 44,
                  child: TextButton(
                    onPressed: _saving ? null : _close,
                    style: TextButton.styleFrom(
                      foregroundColor: context.palette.textPrimary,
                      backgroundColor: Colors.transparent,
                      side: BorderSide.none,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                    child: const Text('取消',
                        style: TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 15)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1: Info
  // ---------------------------------------------------------------------------

  Widget _buildInfoTab() {
    return LyricEditorInfoTab(
      titleController: _titleController,
      artistController: _artistController,
      coverUrlController: _coverUrlController,
      onPickCover: _pickLocalCoverImage,
      onAutoParse: _autoParseTitleAndArtist,
      parsing: _parsing,
    );
  }

  Future<void> _autoParseTitleAndArtist() async {
    Haptics.selection();
    if (_parsing) return;

    // Always parse the B站 raw video title, never the display title: metadata
    // edits overwrite the latter (a wrong song name saved earlier would then
    // be re-parsed forever), but the parse must stay deterministic against the
    // original title no matter how many times the user taps.
    final raw = widget.rawTitle;
    final token = ++_parseToken;
    setState(() => _parsing = true);

    // The lyric-DB cross-validation is the ONLY result ever written to the
    // fields. The rule-based [LyricsEngine.cleanTitle] output is never
    // displayed: it exists purely as the fallback that validation returns
    // when the DB lookup fails. Writing the instant guess while validation
    // was still in flight is what made the fields settle on wrong values
    // (and read as flickering on repeat taps).
    final parsed = await LyricsEngine.cleanTitleWithValidation(
      raw,
      defaultArtist: widget.artistName,
    );

    if (!mounted) return;
    if (token != _parseToken) {
      // Unreachable while the busy-guard holds, but a superseded parse must
      // never leave the button disabled with a stuck spinner.
      setState(() => _parsing = false);
      return;
    }
    setState(() {
      _parsing = false;
      if ((parsed['songTitle'] ?? '').isNotEmpty) {
        _titleController.text = parsed['songTitle']!;
      }
      final parsedArtist = parsed['artist'] ?? '';
      if (parsedArtist.isNotEmpty && parsedArtist != widget.artistName) {
        _artistController.text = parsedArtist;
      }
    });
  }
}
