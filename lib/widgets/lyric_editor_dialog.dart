import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../models/lyric_line.dart';
import '../services/database_service.dart';
import '../services/lyrics_engine.dart';
import '../theme/app_theme.dart';
import '../theme/haptics.dart';
import 'lrc_text_editor_pane.dart';
import 'lyric_editor_info_tab.dart';
import 'lyric_preview_pane.dart';
import 'lyric_result_row.dart';
import 'segment_tabs.dart';

class LyricEditorDialog extends StatefulWidget {
  final String songTitle;
  /// The B站 raw video title. 智能识别 must parse this, never [songTitle]:
  /// metadata edits overwrite [songTitle] but the parse has to stay
  /// deterministic against the original title.
  final String rawTitle;
  final String artistName;
  final String? coverUrl;
  final ValueNotifier<Duration>? positionNotifier;
  final List<LyricLine>? currentLines;
  final Function(LyricsResult) onApplyLyrics;
  final Function(String title, String artist, String coverUrl)? onUpdateMetadata;
  final VoidCallback? onClose;

  /// Which tab to land on: 0 = 信息, 1 = 歌词.
  final int initialTabIndex;

  /// The playing track's id, used to look up the real provider of the
  /// currently-active lyrics so the pinned row shows it, not a redundant
  /// "当前使用" label under a title that already says 当前歌词.
  final String? currentTrackId;

  const LyricEditorDialog({
    super.key,
    required this.songTitle,
    required this.rawTitle,
    required this.artistName,
    this.coverUrl,
    this.positionNotifier,
    this.currentLines,
    required this.onApplyLyrics,
    this.onUpdateMetadata,
    this.onClose,
    this.initialTabIndex = 0,
    this.currentTrackId,
  });

  @override
  State<LyricEditorDialog> createState() => _LyricEditorDialogState();
}

class _LyricEditorDialogState extends State<LyricEditorDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  late TextEditingController _titleController;
  late TextEditingController _artistController;
  late TextEditingController _coverUrlController;

  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _lrcController = TextEditingController();

  final ValueNotifier<Duration> _idlePosition = ValueNotifier(Duration.zero);

  List<LyricsResult> _searchResults = [];
  final List<LyricsResult> _pastedResults = [];
  int? _selectedIndex;
  LyricsResult? _previewingResult;
  double _previewOffset = 0.0;
  bool _calibrating = false;
  bool _isSearching = false;

  /// Monotonic guard so a slow provider response from an older query can
  /// never overwrite the results of a newer one.
  int _searchToken = 0;

  /// The artist/song pair behind the auto-composed search field. While the
  /// field still holds exactly "$artist $song" the search is issued with the
  /// parts separated — NetEase matching fails short song names (岁月, 2
  /// chars) against a compound query, which made auto-searches for such
  /// songs come up empty. User-typed text goes through as one free query.
  String _searchArtist = '';
  String _searchSong = '';

  /// Monotonic guard for 智能识别: only the LAST tap's validated result may
  /// write the fields, no matter which of several in-flight parses completes.
  int _parseToken = 0;

  /// True while a 智能识别 validation lookup is in flight. The button shows a
  /// spinner instead of guessing into the fields.
  bool _parsing = false;

  /// Real provider of the active lyrics (read from the cache); shown on the
  /// pinned 当前歌词 row.
  String? _currentSourceLabel;

  /// True while the full-screen LRC text editor is showing.
  bool _inLrcEditor = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
        length: 2, vsync: this, initialIndex: widget.initialTabIndex);
    _titleController = TextEditingController(text: widget.songTitle);
    _artistController = TextEditingController(text: widget.artistName);
    _coverUrlController = TextEditingController(text: widget.coverUrl ?? '');

    _tabController.addListener(() {
      setState(() {});
    });
    // No listener on the title/artist/cover controllers: nothing in build
    // reads their text (fields own it, save reads it at 确认), so a keystroke
    // used to rebuild the entire dialog — search results included — for
    // nothing.
    _searchArtist = widget.artistName;
    _searchSong = widget.songTitle;
    _searchController.text = '${widget.artistName} ${widget.songTitle}'.trim();
    _searchResults = _pinnedResults();
    _performSearch();

    // Surface the real provider of the active lyrics on the pinned row.
    final trackId = widget.currentTrackId;
    if (trackId != null) {
      DatabaseService.getCachedLyrics(trackId).then((cached) {
        if (mounted && cached != null && cached.source != 'none') {
          setState(() => _currentSourceLabel = cached.source);
        }
      });
    }
  }

  @override
  void dispose() {
    _tabController.dispose();
    _titleController.dispose();
    _artistController.dispose();
    _coverUrlController.dispose();
    _searchController.dispose();
    _lrcController.dispose();
    _idlePosition.dispose();
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
        final coversDir = Directory('${docs.path}/bilibeat_covers');
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
  // Search & results
  // ---------------------------------------------------------------------------

  String _fingerprint(List<LyricLine> lines) => lines
      .map((l) => l.text.trim())
      .where((t) => t.isNotEmpty)
      .join('\n');

  bool _matchesCurrent(LyricsResult r) {
    final current = widget.currentLines;
    if (current == null || current.isEmpty) return false;
    return _fingerprint(r.lines) == _fingerprint(current);
  }

  List<LyricsResult> _pinnedResults() {
    final pinned = <LyricsResult>[];
    final current = widget.currentLines;
    if (current != null && current.isNotEmpty) {
      pinned.add(LyricsResult(
        source: 'current',
        songTitle: widget.songTitle,
        artistName: widget.artistName,
        lines: current,
      ));
    }
    for (final p in _pastedResults) {
      if (!_matchesCurrent(p)) pinned.add(p);
    }
    return pinned;
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() => _searchResults = _pinnedResults());
      return;
    }
    setState(() {
      _isSearching = true;
      _selectedIndex = null;
      _previewingResult = null;
    });

    final token = ++_searchToken;

    // Only the newest search may commit.
    final combo = '$_searchArtist $_searchSong'.trim();
    final netease = (query == combo && _searchSong.isNotEmpty)
        ? await LyricsEngine.fetchFromNetEase(_searchSong,
            artist: _searchArtist.isEmpty ? null : _searchArtist)
        : await LyricsEngine.fetchFromNetEase(query);

    if (!mounted || token != _searchToken) return;
    final results = <LyricsResult>[
      ..._pinnedResults(),
      if (netease != null) netease,
    ];
    setState(() {
      _searchResults = results;
      _isSearching = false;
    });
  }

  String _snippet(LyricsResult res) {
    final texts = res.lines
        .map((l) => l.text.trim())
        .where((t) => t.isNotEmpty)
        .take(2)
        .join(' / ');
    return texts.isEmpty ? '无文本' : texts;
  }

  // ---------------------------------------------------------------------------
  // Apply / calibration
  // ---------------------------------------------------------------------------

  void _applyLyricResult(LyricsResult res, {double offset = 0.0}) {
    final adjustedLines = offset == 0.0
        ? res.lines
        : res.lines
            .map((l) => LyricLine(
                  time: (l.time + offset).clamp(0.0, 99999.0),
                  text: l.text,
                  translation: l.translation,
                ))
            .toList();

    widget.onApplyLyrics(LyricsResult(
      source: res.source,
      songTitle: res.songTitle,
      artistName: res.artistName,
      lines: adjustedLines,
    ));
  }

  void _applyTapCalibration(double offset) {
    setState(() => _previewOffset = offset);
  }

  // ---------------------------------------------------------------------------
  // LRC text editor
  // ---------------------------------------------------------------------------

  /// Opens the LRC editor. If [res] is given its lines are serialised into
  /// the text field for editing; otherwise the field starts empty (paste).
  void _openLrcEditor(LyricsResult? res) {
    _lrcController.text =
        (res != null && res.lines.isNotEmpty) ? LyricsEngine.toLrc(res.lines) : '';
    setState(() {
      _inLrcEditor = true;
      _previewingResult = null;
      _calibrating = false;
    });
  }

  /// Parses the editor text and applies it directly, returning to the
  /// player's lyrics view.
  void _confirmLrcEdit() {
    final text = _lrcController.text.trim();
    if (text.isEmpty) return;

    final lines = LyricsEngine.parseLrc(text);
    final result = LyricsResult(
      source: 'user',
      songTitle: '自定义歌词',
      artistName: _artistController.text.trim().isNotEmpty
          ? _artistController.text.trim()
          : '自定义',
      lines: lines.isNotEmpty ? lines : [LyricLine(time: 0, text: text)],
    );

    // Keep it in the pasted list so it shows up in future searches.
    _pastedResults.removeWhere(
        (r) => _fingerprint(r.lines) == _fingerprint(result.lines));
    _pastedResults.add(result);

    // Apply directly and return to the player's lyrics view.
    _applyLyricResult(result);
  }

  // ---------------------------------------------------------------------------
  // Metadata
  // ---------------------------------------------------------------------------

  void _saveAll() {
    final newTitle = _titleController.text.trim();
    final newArtist = _artistController.text.trim();
    final newCover = _coverUrlController.text.trim();

    final hasMetadataEdit = newTitle.isNotEmpty &&
        (newTitle != widget.songTitle ||
         newArtist != widget.artistName ||
         newCover != (widget.coverUrl ?? ''));

    if (hasMetadataEdit && widget.onUpdateMetadata != null) {
      widget.onUpdateMetadata!(
        newTitle,
        newArtist.isNotEmpty ? newArtist : '未知UP主',
        newCover,
      );
    }

    final sel = _selectedResult ??
        (_previewOffset != 0.0 &&
                widget.currentLines != null &&
                widget.currentLines!.isNotEmpty
            ? LyricsResult(
                source: 'current',
                songTitle: newTitle.isNotEmpty ? newTitle : widget.songTitle,
                artistName: newArtist.isNotEmpty ? newArtist : widget.artistName,
                lines: widget.currentLines!,
              )
            : null);

    if (sel != null) {
      _applyLyricResult(sel, offset: _previewOffset);
    } else if (!hasMetadataEdit ||
        // Metadata-only save with no caller-side handler: nobody else is
        // going to close this dialog, so it must close itself.
        widget.onUpdateMetadata == null) {
      _close();
    }
  }

  // ---------------------------------------------------------------------------
  // Offset bar (calibration controls)
  // ---------------------------------------------------------------------------



  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  void _close() {
    if (widget.onClose != null) {
      widget.onClose!();
    } else {
      Navigator.pop(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_inLrcEditor || _previewingResult != null) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
        child: SafeArea(bottom: false, child: _buildLyricsTab()),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          // Tabs — animation-driven indicator that follows drag in real time
          Row(
            children: [
              Expanded(
                child: SegmentTabs(
                  labels: const ['信息', '歌词'],
                  animation: _tabController.animation!,
                  onTap: (i) => _tabController.animateTo(i),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(left: 12, right: 2),
                child: Image.asset('assets/logo.png', height: 36),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildInfoTab(),
                _buildLyricsTab(),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // Single stationary 确认 button fixed at the bottom of the dialog
          SizedBox(
            width: double.infinity,
            height: 44,
            child: ElevatedButton(
              onPressed: _saveAll,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12)),
              ),
              child: const Text('确认',
                  style: TextStyle(
                      color: AppColors.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
            ),
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
    var research = false;
    setState(() {
      _parsing = false;
      if ((parsed['songTitle'] ?? '').isNotEmpty) {
        _titleController.text = parsed['songTitle']!;
      }
      final parsedArtist = parsed['artist'] ?? '';
      if (parsedArtist.isNotEmpty && parsedArtist != widget.artistName) {
        _artistController.text = parsedArtist;
      }
      // Re-aim the auto-composed search at the recognised pair — the
      // initial query was "UP主名 标题", which is why the first search
      // found nothing. A query the user typed themselves is left alone.
      final currentQuery = _searchController.text.trim();
      final oldCombo = '$_searchArtist $_searchSong'.trim();
      final newSong = parsed['songTitle'] ?? '';
      if (newSong.isNotEmpty &&
          (currentQuery.isEmpty || currentQuery == oldCombo)) {
        final newArtist = parsed['artist'] ?? '';
        _searchArtist = newArtist.isNotEmpty ? newArtist : _searchArtist;
        _searchSong = newSong;
        _searchController.text = '$_searchArtist $_searchSong'.trim();
        research = true;
      }
    });
    if (research) _performSearch();
  }


  // ---------------------------------------------------------------------------
  // Tab 2: Lyrics (three states: list → LRC editor → preview)
  // ---------------------------------------------------------------------------

  Widget _buildLyricsTab() {
    if (_previewingResult != null) return _buildPreview();
    if (_inLrcEditor) return _buildLrcEditor();
    return _buildResultList();
  }

  // --- State A: search results + paste card ---

  Widget _buildResultList() {
    return Column(
      children: [
        // Search bar
        TextField(
          controller: _searchController,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 14),
          onSubmitted: (_) => _performSearch(),
          decoration: InputDecoration(
            hintText: '搜索歌曲或歌手',
            hintStyle: const TextStyle(color: AppColors.textFaint),
            suffixIcon: _isSearching
                ? const Padding(
                    padding: EdgeInsets.all(12),
                    child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: AppColors.accent)),
                  )
                : IconButton(
                    icon: const Icon(Icons.search, color: AppColors.accent),
                    onPressed: _performSearch,
                  ),
            filled: true,
            fillColor: AppColors.white12,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          ),
        ),
        const SizedBox(height: 10),

        // Results
        Expanded(
          child: (_isSearching && _searchResults.isEmpty)
              ? const Center(
                  child: CircularProgressIndicator(color: AppColors.accent))
              : _searchResults.isEmpty
                  ? const Center(
                      child: Text('无结果',
                          style: TextStyle(color: AppColors.textFaint)))
                  : ListView.builder(
                      itemCount: _searchResults.length + 1, // +1 for paste card
                      itemBuilder: (context, index) {
                        // Last item: paste / edit LRC card
                        if (index == _searchResults.length) {
                          return _pasteCard();
                        }
                        return _resultRow(_searchResults[index], index);
                      },
                    ),
        ),
      ],
    );
  }

  /// The result highlighted for the 确认 button, or null when nothing is
  /// selected (e.g. right after a fresh search).
  LyricsResult? get _selectedResult => (_selectedIndex != null &&
          _selectedIndex! >= 0 &&
          _selectedIndex! < _searchResults.length)
      ? _searchResults[_selectedIndex!]
      : null;

  /// Human-readable provider name. For the pinned current row we surface the
  /// lyrics' real origin (read from the cache). When the origin is unknown
  /// (no cache entry, or a re-applied 'current' result) the label is empty:
  /// the row title already says 当前歌词, so a second 当前 is pure repetition —
  /// the row then shows only the line count.
  String _sourceLabel(LyricsResult res) {
    final raw = res.source == 'current'
        ? (_currentSourceLabel ?? '')
        : res.source;
    switch (raw) {
      case 'netease':
        return '网易云';
      case 'user':
        return '自定义';
      case '':
      case 'current':
        return '';
      default:
        return raw.toUpperCase();
    }
  }

  Widget _resultRow(LyricsResult res, int index) {
    return LyricResultRow(
      result: res,
      isSelected: _selectedIndex == index,
      sourceLabel: _sourceLabel(res),
      snippet: _snippet(res),
      onPreview: () {
        setState(() {
          _selectedIndex = index;
          _previewingResult = res;
          _previewOffset = 0.0;
          _calibrating = false;
        });
      },
      onApply: () {
        setState(() => _selectedIndex = index);
        _applyLyricResult(res);
      },
    );
  }

  /// "粘贴 LRC" card at the bottom of the results list.
  Widget _pasteCard() {
    return InkWell(
      borderRadius: BorderRadius.circular(14),
      onTap: () => _openLrcEditor(null),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: AppColors.white05,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.white12),
        ),
        child: const Row(
          children: [
            Icon(Icons.content_paste, color: AppColors.accent, size: 18),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                '粘贴 LRC 文本',
                style: TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600),
              ),
            ),
            Icon(Icons.arrow_forward_ios, color: AppColors.textFaint, size: 14),
          ],
        ),
      ),
    );
  }

  // --- State B: LRC text editor ---

  Widget _buildLrcEditor() {
    return LrcTextEditorPane(
      controller: _lrcController,
      onCancel: () => setState(() => _inLrcEditor = false),
      onSave: _confirmLrcEdit,
    );
  }
  // --- State C: preview + calibration ---

  Widget _buildPreview() {
    return LyricPreviewPane(
      result: _previewingResult!,
      fallbackTitle: widget.songTitle,
      positionNotifier: widget.positionNotifier ?? _idlePosition,
      offset: _previewOffset,
      calibrating: _calibrating,
      onBack: () => setState(() {
        _previewingResult = null;
        _calibrating = false;
      }),
      onEditLrc: () => _openLrcEditor(_previewingResult),
      onCalibrateTap: _applyTapCalibration,
      onStartCalibrating: () => setState(() => _calibrating = true),
      onApply: () =>
          _applyLyricResult(_previewingResult!, offset: _previewOffset),
    );
  }
}
