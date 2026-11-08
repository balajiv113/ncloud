import 'package:flutter/foundation.dart' show listEquals;

import '../../../models.dart';
import 'library_view.dart';

/// Where an album comes from. Server albums are the ordinary case and carry
/// no mark; Smart and Shared albums are told apart by an icon.
enum AlbumKind { smart, shared, server }

/// One album in the merged Albums list.
class AlbumEntry {
  const AlbumEntry({
    required this.kind,
    required this.name,
    this.subtitle = '',
    this.count = '',
    this.cover,
    this.modified,
    this.path = const [],
    this.server,
  });

  final AlbumKind kind;
  final String name;
  final String subtitle;
  final String count;
  final CloudFile? cover;

  /// Newest file in the album, when the source reports one.
  final DateTime? modified;

  /// Folder of a Smart or Shared album.
  final List<String> path;

  /// The server album, for [AlbumKind.server].
  final CloudAlbum? server;

  String get key => switch (kind) {
    AlbumKind.server => 'server|${server!.reference.join('/')}',
    _ => '${kind.name}|${path.join('/')}',
  };

  /// Kind read aloud, since the icon alone is not announced.
  String? get kindLabel => switch (kind) {
    AlbumKind.smart => 'Smart album',
    AlbumKind.shared => 'Shared with you',
    AlbumKind.server => null,
  };
}

DateTime? _newest(Iterable<CloudFile> files) => files
    .map((f) => f.modified)
    .nonNulls
    .fold<DateTime?>(null, (a, b) => a == null || b.isAfter(a) ? b : a);

/// Every album matching [query], as one list. [root] is the photo source, which
/// names its loose photos "Photos at root".
///
/// By name, albums are alphabetical. By date they run newest or oldest first
/// with undated server albums after, alphabetical. Other sorts keep the
/// discovery order: Smart, Shared, then server albums.
List<AlbumEntry> albumEntries({
  required List<SmartAlbum> smart,
  required List<SmartAlbum> shared,
  required List<CloudAlbum> server,
  required List<String> root,
  required String query,
  required LibrarySort sort,
}) {
  final needle = query.toLowerCase();
  bool matches(String text) =>
      needle.isEmpty || text.toLowerCase().contains(needle);
  final entries = [
    for (final album in smart)
      if (matches('${album.name} ${album.path.join(' ')}'))
        AlbumEntry(
          kind: AlbumKind.smart,
          name: listEquals(album.path, root) ? 'Photos at root' : album.name,
          subtitle: album.path.length <= root.length + 1
              ? ''
              : album.path
                    .skip(root.length)
                    .take(album.path.length - root.length - 1)
                    .join(' / '),
          cover: album.files.firstOrNull,
          modified: _newest(album.files),
          path: album.path,
        ),
    for (final album in shared)
      if (matches(album.name))
        AlbumEntry(
          kind: AlbumKind.shared,
          name: album.name,
          cover: album.files.firstOrNull,
          modified: _newest(album.files),
          path: album.path,
        ),
    for (final album in server)
      if (matches(album.name))
        AlbumEntry(
          kind: AlbumKind.server,
          name: album.name,
          count: '${album.count} items',
          cover: album.cover,
          server: album,
        ),
  ];
  int byName(AlbumEntry a, AlbumEntry b) =>
      a.name.toLowerCase().compareTo(b.name.toLowerCase());
  switch (sort) {
    case LibrarySort.name:
      entries.sort(byName);
    case LibrarySort.newest || LibrarySort.oldest:
      final newest = sort == LibrarySort.newest;
      entries.sort((a, b) {
        final x = a.modified;
        final y = b.modified;
        if (x == null || y == null) {
          return x == y ? byName(a, b) : (x == null ? 1 : -1);
        }
        final order = newest ? y.compareTo(x) : x.compareTo(y);
        return order == 0 ? byName(a, b) : order;
      });
    case LibrarySort.size:
      break;
  }
  return entries;
}
