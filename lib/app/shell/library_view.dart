import '../../models.dart';

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
  final needle = query.toLowerCase();
  final visible = files.where((f) {
    if (needle.isNotEmpty && !f.name.toLowerCase().contains(needle)) {
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
  });
  // Sorting compares each file many times, so what it compares is worked out
  // once per file: building a key or a date inside the comparator costs far
  // more than the sort itself on a large library.
  final unknown = DateTime(1970).microsecondsSinceEpoch;
  final entries = [
    for (final f in visible)
      (
        file: f,
        key: f.key,
        date: f.timelineDate?.microsecondsSinceEpoch ?? unknown,
        taken: f.taken?.microsecondsSinceEpoch ?? unknown,
        name: sort == LibrarySort.name ? f.name.toLowerCase() : '',
      ),
  ];
  entries.sort((a, b) {
    if (a.file.isDirectory != b.file.isDirectory) {
      return a.file.isDirectory ? -1 : 1;
    }
    var newest = b.date.compareTo(a.date);
    if (newest == 0) newest = b.taken.compareTo(a.taken);
    final order = switch (sort) {
      LibrarySort.newest => newest,
      LibrarySort.oldest => -newest,
      LibrarySort.name => a.name.compareTo(b.name),
      LibrarySort.size => b.file.size.compareTo(a.file.size),
    };
    return order == 0 ? a.key.compareTo(b.key) : order;
  });
  return [for (final entry in entries) entry.file];
}
