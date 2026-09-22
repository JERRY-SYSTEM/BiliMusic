import 'dart:convert';
import 'dart:typed_data';

import '../models/bili_session.dart';
import '../models/bili_favorite_collection.dart';
import '../models/lyric_line.dart';
import '../models/playlist.dart';
import '../models/track.dart';
import 'bili_auth_service.dart';
import 'bili_favorites_service.dart';
import 'bilibili_sdk.dart';
import 'database_service.dart';

class AppTransferException implements Exception {
  const AppTransferException(this.message);

  final String message;

  @override
  String toString() => message;
}

class AppImportPlaylistPreview {
  const AppImportPlaylistPreview({
    required this.id,
    required this.name,
    required this.isOnline,
    required this.trackCount,
  });

  final String id;
  final String name;
  final bool isOnline;
  final int trackCount;
}

class AppImportPreview {
  const AppImportPreview({
    required this.hasSession,
    required this.favoriteTrackCount,
    required this.playlists,
  });

  final bool hasSession;
  final int favoriteTrackCount;
  final List<AppImportPlaylistPreview> playlists;

  int get localPlaylistCount =>
      playlists.where((playlist) => !playlist.isOnline).length;

  int get onlinePlaylistCount =>
      playlists.where((playlist) => playlist.isOnline).length;
}

class AppImportSelection {
  const AppImportSelection({
    required this.importSession,
    required this.importFavorites,
    required this.playlistIds,
  });

  final bool importSession;
  final bool importFavorites;
  final Set<String> playlistIds;
}

class AppImportResult {
  const AppImportResult({
    required this.playlistCount,
    required this.trackCount,
    required this.skippedTrackCount,
    required this.failedOnlinePlaylistCount,
    this.parseWarnings = const [],
  });

  final int playlistCount;
  final int trackCount;
  final int skippedTrackCount;
  final int failedOnlinePlaylistCount;
  final List<String> parseWarnings;
}

class AppTransferService {
  const AppTransferService({BiliAuthController? auth, this.fetchVideoInfo, this.fetchOnlineTracks, this.fetchCollections}) : _authOverride = auth;

  final BiliAuthController? _authOverride;
  BiliAuthController get _auth => _authOverride ?? BiliAuthController.instance;
  final Future<List<Track>> Function(String)? fetchVideoInfo;
  final Future<List<Track>> Function(BiliSession, String)? fetchOnlineTracks;
  final Future<List<BiliFavoriteCollection>> Function(BiliSession)? fetchCollections;

  static const int schemaVersion = 2;

  Future<String> buildExportJson() async {
    await _auth.initialize();
    final playlists = await DatabaseService.getPlaylists();
    final referencedIds = playlists
        .expand((playlist) => playlist.tracks)
        .map((track) => track.id)
        .toSet();
    final lyrics = <String, Map<String, dynamic>>{};
    for (final trackId in referencedIds) {
      final selection = await DatabaseService.getLyricsSelection(trackId);
      if (selection != null) {
        final reference = Map<String, dynamic>.from(selection['reference'] as Map);
        lyrics[trackId] = {
          'reference': {
            'provider': reference['provider'],
            'id': reference['id'],
          },
          'offset': selection['offset'],
        };
      }
    }
    final session = _auth.session;
    final bundle = <String, dynamic>{
      'schemaVersion': schemaVersion,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      if (session != null && session.isLoggedIn) 'session': session.toMap(),
      'playlists': playlists.map(_playlistToJson).toList(),
      'lyrics': lyrics,
    };
    return const JsonEncoder.withIndent('  ').convert(bundle);
  }

  AppImportPreview previewImport(Uint8List bytes) {
    final bundle = _parse(bytes);
    final favorites = bundle.playlists.where(
      (playlist) => playlist.id == Playlist.favoritesId,
    );
    return AppImportPreview(
      hasSession: bundle.session != null,
      favoriteTrackCount:
          favorites.isEmpty ? 0 : favorites.first.tracks.length,
      playlists: bundle.playlists
          .where((playlist) => playlist.id != Playlist.favoritesId)
          .map(
            (playlist) => AppImportPlaylistPreview(
              id: playlist.id,
              name: playlist.name,
              isOnline: playlist.isOnline,
              trackCount: playlist.tracks.length,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<AppImportResult> importBytes({
    required Uint8List bytes,
    required AppImportSelection selection,
  }) async {
    await _auth.initialize();
    final bundle = _parse(bytes);
    final current = (await DatabaseService.getPlaylists())
        .map(_copyPlaylist)
        .toList();
    final selectedSession = selection.importSession ? bundle.session : null;
    final syncSession = selectedSession ?? _auth.session;
    final existingTracks = <String, Track>{
      for (final playlist in current)
        for (final track in playlist.tracks) track.id: track,
    };
    final hydrateCache = <String, Future<Track?>>{};
    final importedTrackIds = <String>{};
    final trackOverrides = <String, Track>{};
    var playlistCount = 0;
    var trackCount = 0;
    var skippedTrackCount = bundle.warnings
        .where((warning) => warning.startsWith('跳过歌单'))
        .length;
    var failedOnlinePlaylistCount = 0;

    Future<Track?> hydrate(_BackupTrack reference) async {
      final details = await hydrateCache.putIfAbsent(
        reference.id,
        () => _fetchTrack(reference),
      );
      final base = details ?? existingTracks[reference.id];
      return base?.copyWith(
        title: reference.title,
        uploader: reference.uploader,
        coverUrl: '',
        musicSource: reference.musicSource,
        musicId: reference.musicId,
      );
    }

    // Bound concurrent network requests while preserving backup order.
    Future<List<Track?>> restoreTracks(List<_BackupTrack> tracks) async {
      final restored = <Track?>[];
      for (var offset = 0; offset < tracks.length; offset += 4) {
        restored.addAll(await Future.wait(
          tracks.skip(offset).take(4).map(hydrate),
        ));
      }
      return restored;
    }

    for (final backupPlaylist in bundle.playlists) {
      final isFavorites = backupPlaylist.id == Playlist.favoritesId;
      if (isFavorites && !selection.importFavorites) continue;
      if (!isFavorites &&
          !selection.playlistIds.contains(backupPlaylist.id)) {
        continue;
      }

      List<Track> importedTracks;
      String importedName = backupPlaylist.name;
      String? importedCover;

      if (backupPlaylist.isOnline) {
        List<Track>? cloudTracks;
        if (syncSession != null &&
            syncSession.isLoggedIn &&
            backupPlaylist.remoteId != null) {
          try {
            cloudTracks = await (fetchOnlineTracks ?? BiliFavoritesService.fetchTracks)(
              syncSession,
              backupPlaylist.remoteId!,
            );
            try {
              final collections =
                  await (fetchCollections ?? BiliFavoritesService.fetchCollections)(syncSession);
              for (final collection in collections) {
                if (collection.id == backupPlaylist.remoteId) {
                  importedName = collection.name;
                  importedCover = collection.coverUrl;
                  break;
                }
              }
            } catch (_) {
              // Track synchronization succeeded. Collection decoration is
              // optional and must not downgrade it to a failed sync.
            }
          } catch (_) {
            failedOnlinePlaylistCount++;
          }
        } else {
          failedOnlinePlaylistCount++;
        }

        if (cloudTracks != null) {
          final overrides = {
            for (final track in backupPlaylist.tracks) track.id: track,
          };
          importedTracks = cloudTracks.map((fresh) {
            final override = overrides[fresh.id];
            return override == null
                ? fresh
                : fresh.copyWith(
                    title: override.title,
                    uploader: override.uploader,
                    musicSource: override.musicSource,
                    musicId: override.musicId,
                  );
          }).toList();
        } else {
          final restored = await restoreTracks(backupPlaylist.tracks);
          importedTracks = restored.whereType<Track>().toList();
          skippedTrackCount += restored.where((track) => track == null).length;
        }

        current.removeWhere(
          (playlist) =>
              playlist.id == backupPlaylist.id ||
              (backupPlaylist.remoteId != null &&
                  playlist.remoteId == backupPlaylist.remoteId),
        );
        current.add(
          Playlist(
            id: backupPlaylist.id,
            name: importedName,
            coverUrl: importedCover,
            remoteId: backupPlaylist.remoteId,
            isOnline: true,
            lastSyncedAt: cloudTracks == null ? null : DateTime.now(),
            tracks: importedTracks,
          ),
        );
      } else {
        final restored = await restoreTracks(backupPlaylist.tracks);
        importedTracks = restored.whereType<Track>().toList();
        skippedTrackCount += restored.where((track) => track == null).length;
        final existingIndex = current.indexWhere(
          (playlist) => playlist.id == backupPlaylist.id,
        );
        if (existingIndex == -1) {
          current.add(
            Playlist(
              id: backupPlaylist.id,
              name: backupPlaylist.name,
              tracks: importedTracks,
            ),
          );
        } else {
          final existing = current[existingIndex];
          final importedIds = importedTracks.map((track) => track.id).toSet();
          current[existingIndex] = Playlist(
            id: existing.id,
            name: backupPlaylist.name,
            tracks: <Track>[
              ...importedTracks,
              ...existing.tracks.where(
                (track) => !importedIds.contains(track.id),
              ),
            ],
          );
        }
      }

      playlistCount++;
      trackCount += importedTracks.length;
      importedTrackIds.addAll(importedTracks.map((track) => track.id));
      final backedUpTracks = {
        for (final track in backupPlaylist.tracks) track.id: track,
      };
      for (final track in importedTracks) {
        if (backedUpTracks.containsKey(track.id)) {
          trackOverrides[track.id] = track;
        }
      }
    }

    for (var index = 0; index < current.length; index++) {
      final playlist = current[index];
      current[index] = Playlist(
        id: playlist.id,
        name: playlist.name,
        coverUrl: playlist.coverUrl,
        remoteId: playlist.remoteId,
        isOnline: playlist.isOnline,
        lastSyncedAt: playlist.lastSyncedAt,
        tracks: playlist.tracks.map((track) {
          final override = trackOverrides[track.id];
          return override == null
              ? track
              : track.copyWith(
                  title: override.title,
                  uploader: override.uploader,
                  musicSource: override.musicSource,
                  musicId: override.musicId,
                );
        }).toList(),
      );
    }

    final selectedLyrics = Map<String, Map<String, dynamic>>.fromEntries(
      bundle.lyrics.entries.where(
        (entry) => importedTrackIds.contains(entry.key),
      ),
    );
    await DatabaseService.replacePlaylistsAndLyrics(
      playlists: current,
      lyrics: selectedLyrics,
      trackOverrides: trackOverrides,
      session: selectedSession,
    );
    if (selectedSession != null) {
      _auth.acceptCommittedSession(selectedSession);
    }
    return AppImportResult(
      playlistCount: playlistCount,
      trackCount: trackCount,
      skippedTrackCount: skippedTrackCount,
      failedOnlinePlaylistCount: failedOnlinePlaylistCount,
      parseWarnings: bundle.warnings,
    );
  }

  Future<Track?> _fetchTrack(_BackupTrack reference) async {
    try {
      final candidates = await (fetchVideoInfo ?? BilibiliSdk.fetchVideoInfo)(reference.bvid);
      Track? details;
      for (final candidate in candidates) {
        if (candidate.id == reference.id) {
          details = candidate;
          break;
        }
      }
      if (details == null) return null;
      return details;
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic> _playlistToJson(Playlist playlist) => {
        'id': playlist.id,
        'name': playlist.name,
        'isOnline': playlist.isOnline,
        if (playlist.remoteId != null) 'remoteId': playlist.remoteId,
        'tracks': playlist.tracks
            .map(
              (track) => {
                'id': track.id,
                'bvid': track.bvid,
                'cid': track.cid,
                'title': track.title,
                'uploader': track.uploader,
                'musicSource': track.musicSource,
                'musicId': track.musicId,
              },
            )
            .toList(),
      };

  Playlist _copyPlaylist(Playlist playlist) => Playlist(
        id: playlist.id,
        name: playlist.name,
        coverUrl: playlist.coverUrl,
        remoteId: playlist.remoteId,
        isOnline: playlist.isOnline,
        lastSyncedAt: playlist.lastSyncedAt,
        tracks: playlist.tracks,
      );

  _BackupBundle _parse(Uint8List bytes) {
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map) {
        throw const AppTransferException('备份文件格式不正确');
      }
      final json = Map<String, dynamic>.from(decoded);
      final version = json['schemaVersion'];
      if (version is! int) {
        throw const AppTransferException('备份文件缺少有效的版本信息');
      }
      if (version != schemaVersion) {
        throw const AppTransferException('备份版本与当前 BiliMusic 不匹配');
      }
      final exportedAt = json['exportedAt'];
      if (exportedAt is! String || DateTime.tryParse(exportedAt) == null) {
        throw const AppTransferException('备份时间无效');
      }
      final rawPlaylists = json['playlists'];
      if (rawPlaylists is! List) {
        throw const AppTransferException('备份中的歌单数据无效');
      }
      final warnings = <String>[];
      final playlists = <_BackupPlaylist>[];
      for (var index = 0; index < rawPlaylists.length; index++) {
        final item = rawPlaylists[index];
        try {
          playlists.add(_BackupPlaylist.fromJson(
            _stringMap(item),
            warnings: warnings,
          ));
        } catch (error) {
          throw AppTransferException('备份中第 ${index + 1} 个歌单无效：$error');
        }
      }
      final ids = playlists.map((playlist) => playlist.id).toSet();
      if (ids.length != playlists.length) {
        throw const AppTransferException('备份中存在重复的歌单 ID');
      }
      BiliSession? session;
      if (json['session'] != null) {
        session = BiliSession.fromMap(_stringMap(json['session']));
        if (!session.isLoggedIn || session.cookie.trim().isEmpty) {
          throw const AppTransferException('备份中的登录信息不完整');
        }
      }
      final lyrics = <String, Map<String, dynamic>>{};
      final rawLyrics = json['lyrics'];
      if (rawLyrics is! Map) {
        throw const AppTransferException('备份中的歌词数据无效');
      }
      for (final entry in rawLyrics.entries) {
        try {
          final value = _stringMap(entry.value);
          if (value['reference'] is! Map || value['offset'] is! num) {
            throw const FormatException('结构无效');
          }
          final reference = _stringMap(value['reference']);
          LyricsReference.fromMap(reference);
          lyrics[entry.key.toString()] = {
            'reference': reference,
            'offset': value['offset'],
          };
        } catch (error) {
          warnings.add('跳过歌词 ${entry.key}：$error');
        }
      }
      return _BackupBundle(
        session: session,
        playlists: playlists,
        lyrics: lyrics,
        warnings: warnings,
      );
    } on AppTransferException {
      rethrow;
    } catch (_) {
      throw const AppTransferException('无法读取备份文件，文件可能已损坏');
    }
  }

  Map<String, dynamic> _stringMap(Object? value) {
    if (value is! Map) {
      throw const AppTransferException('备份数据结构无效');
    }
    return Map<String, dynamic>.from(value);
  }
}

class _BackupBundle {
  const _BackupBundle({
    required this.session,
    required this.playlists,
    required this.lyrics,
    required this.warnings,
  });

  final BiliSession? session;
  final List<_BackupPlaylist> playlists;
  final Map<String, Map<String, dynamic>> lyrics;
  final List<String> warnings;
}

class _BackupPlaylist {
  const _BackupPlaylist({
    required this.id,
    required this.name,
    required this.isOnline,
    required this.remoteId,
    required this.tracks,
  });

  factory _BackupPlaylist.fromJson(Map<String, dynamic> json, {required List<String> warnings}) {
    final id = json['id'];
    final name = json['name'];
    final isOnline = json['isOnline'];
    final remoteId = json['remoteId'];
    final rawTracks = json['tracks'];
    if (id is! String ||
        id.trim().isEmpty ||
        name is! String ||
        isOnline is! bool ||
        rawTracks is! List ||
        (isOnline && (remoteId is! String || remoteId.trim().isEmpty))) {
      throw const AppTransferException('备份中的歌单数据无效');
    }
    if (id == Playlist.favoritesId && isOnline) {
      throw const AppTransferException('收藏不能是在线歌单');
    }
    final tracks = <_BackupTrack>[];
    for (var index = 0; index < rawTracks.length; index++) {
      try {
        tracks.add(_BackupTrack.fromJson(
          Map<String, dynamic>.from(rawTracks[index] as Map),
        ));
      } catch (error) {
        warnings.add('跳过歌单“$name”第 ${index + 1} 首歌：$error');
      }
    }
    if (tracks.map((track) => track.id).toSet().length != tracks.length) {
      throw const AppTransferException('备份歌单中存在重复的歌曲 ID');
    }
    return _BackupPlaylist(
      id: id,
      name: name,
      isOnline: isOnline,
      remoteId: remoteId as String?,
      tracks: tracks,
    );
  }

  final String id;
  final String name;
  final bool isOnline;
  final String? remoteId;
  final List<_BackupTrack> tracks;
}

class _BackupTrack {
  const _BackupTrack({
    required this.id,
    required this.bvid,
    required this.cid,
    required this.title,
    required this.uploader,
    required this.musicSource,
    required this.musicId,
  });

  factory _BackupTrack.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final bvid = json['bvid'];
    final cid = json['cid'];
    final title = json['title'];
    final uploader = json['uploader'];
    final musicSource = json['musicSource'];
    final musicId = json['musicId'];
    if (id is! String ||
        id.isEmpty ||
        bvid is! String ||
        bvid.isEmpty ||
        cid is! int ||
        cid < 0 ||
        title is! String ||
        uploader is! String ||
        musicSource is! String ||
        musicId is! String ||
        (musicSource.isEmpty != musicId.isEmpty) ||
        (musicSource.isNotEmpty && !LyricProvider.values.any((p) => p.apiName == musicSource))) {
      throw const AppTransferException('备份中的歌曲标识无效');
    }
    if (!RegExp('^${RegExp.escape(bvid)}_p[1-9][0-9]*\$').hasMatch(id)) {
      throw const AppTransferException('备份中的歌曲分 P 标识无效');
    }
    return _BackupTrack(
      id: id,
      bvid: bvid,
      cid: cid.toInt(),
      title: title,
      uploader: uploader,
      musicSource: musicSource,
      musicId: musicId,
    );
  }

  final String id;
  final String bvid;
  final int cid;
  final String title;
  final String uploader;
  final String musicSource;
  final String musicId;
}
