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

/// The sub-folders of [directory] that hold [items]' media, in first-seen
/// order, so an album can be narrowed to one of them.
List<List<String>> subfolderPaths(
  Iterable<CloudFile> items,
  List<String> directory,
) {
  final children = <String, List<String>>{};
  for (final file in items) {
    if (file.isMedia && file.path.length > directory.length + 1) {
      final path = file.path.take(directory.length + 1).toList();
      children[path.last] = path;
    }
  }
  return children.values.toList();
}
