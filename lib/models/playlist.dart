import 'track.dart';

/// A named, ordered set of tracks.
///
/// `createdAt` and `updatedAt` were carried on every playlist and persisted to
/// disk, but nothing ever read them — nothing sorted by date. They are gone.
class Playlist {
  /// The built-in favorites playlist's stable id. Magic-string comparisons
  /// scattered through the UI and database layer all point at this.
  static const String favoritesId = 'favorites';

  final String id;
  final String name;

  /// A local image path the user picked for this playlist, or null for the
  /// default artwork.
  final String? coverUrl;

  /// Mutated in place by the database layer (add/remove/metadata edits), so it
  /// must always be growable.
  final List<Track> tracks;

  /// Deliberately NOT const. A const constructor lets `Playlist(tracks: [])` be
  /// promoted to a const literal, and a const `[]` is unmodifiable — which
  /// turned "add to 收藏" into `Cannot add to an unmodifiable list`. Keeping the
  /// constructor non-const makes that promotion impossible, and stops
  /// `prefer_const_constructors` from suggesting it back.
  Playlist({
    required this.id,
    required this.name,
    required List<Track> tracks,
    this.coverUrl,
  }) : tracks = List<Track>.of(tracks);

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      if (coverUrl != null) 'coverUrl': coverUrl,
    };
  }

  factory Playlist.fromMap(Map<String, dynamic> map, {List<Track>? tracks}) {
    return Playlist(
      id: map['id'] ?? '',
      name: map['name'] ?? '未命名歌单',
      coverUrl: map['coverUrl'] as String?,
      tracks: tracks ?? [],
    );
  }
}
