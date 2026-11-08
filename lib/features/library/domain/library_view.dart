import '../../../models.dart';

enum MediaFilter { all, photos, videos, favorites }

enum LibrarySort { newest, oldest, name, size }

/// The files a view shows after the search text, sub-folder, media filter and
/// sort. Folders come first and ties fall back to the file key, so the order
/// is stable.
List<CloudFile> filterAndSortFiles(
  Iterable<CloudFile> files, {
  required String query,
  List<String>? subfolder,
  required MediaFilter filter,
  required LibrarySort sort,
  required bool drive,
  required bool collection,
}) {
  final visible = files.where((f) {
    if (query.isNotEmpty &&
        !f.name.toLowerCase().contains(query.toLowerCase())) {
      return false;
    }
    if (subfolder != null && !pathStartsWith(f.path, subfolder)) return false;
    if (f.isDirectory) return drive;
    if (!drive && !f.isMedia && !collection) return false;
    return switch (filter) {
      MediaFilter.all => true,
      MediaFilter.photos => f.isImage,
      MediaFilter.videos => f.isVideo,
      MediaFilter.favorites => f.favorite,
    };
  }).toList();
  visible.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    var newest = (b.timelineDate ?? DateTime(1970)).compareTo(
      a.timelineDate ?? DateTime(1970),
    );
    if (newest == 0) {
      newest = (b.taken ?? DateTime(1970)).compareTo(a.taken ?? DateTime(1970));
    }
    final order = switch (sort) {
      LibrarySort.newest => newest,
      LibrarySort.oldest => -newest,
      LibrarySort.name => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      LibrarySort.size => b.size.compareTo(a.size),
    };
    return order == 0 ? a.key.compareTo(b.key) : order;
  });
  return visible;
}

/// Smart albums whose name or folder matches the search text, ordered by
/// [sort]. Albums have no size, so that order keeps discovery order.
List<SmartAlbum> filterSmartAlbums(
  List<SmartAlbum> albums, {
  required String query,
  required LibrarySort sort,
}) {
  final matching = albums
      .where(
        (a) =>
            query.isEmpty ||
            '${a.name} ${a.path.join(' ')}'.toLowerCase().contains(
              query.toLowerCase(),
            ),
      )
      .toList();
  if (sort == LibrarySort.newest || sort == LibrarySort.oldest) {
    DateTime date(SmartAlbum album) => album.files
        .map((f) => f.modified ?? DateTime(1970))
        .reduce((a, b) => a.isAfter(b) ? a : b);
    final dates = {for (final album in matching) album.key: date(album)};
    matching.sort(
      (a, b) => sort == LibrarySort.newest
          ? dates[b.key]!.compareTo(dates[a.key]!)
          : dates[a.key]!.compareTo(dates[b.key]!),
    );
  } else if (sort == LibrarySort.name) {
    matching.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );
  }
  return matching;
}
