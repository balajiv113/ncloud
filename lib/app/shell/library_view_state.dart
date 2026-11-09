import '../../models.dart';
import 'library_view.dart';

/// What the library screen is currently narrowed to: search text, media
/// filter, sort, grid density, the selected files and which Albums section is
/// expanded. It holds no widgets; the screen calls `setState` around changes.
class LibraryViewState {
  String query = '';
  bool searching = false;
  MediaFilter filter = MediaFilter.all;
  LibrarySort sort = LibrarySort.newest;

  /// Sub-folder an album is narrowed to, or null for all of it.
  List<String>? subfolder;

  /// Photos per row on a phone.
  int density = 3;
  bool albumsExpanded = false;
  bool showPeople = false;
  final Map<String, CloudFile> selected = {};

  /// What the Timeline derived from its files, kept here so it survives
  /// leaving the Timeline for another destination and coming back.
  final MemoSlot timelineMemo = MemoSlot();

  Object? _visibleKey;
  List<CloudFile> _visibleFiles = const [];

  bool get selecting => selected.isNotEmpty;

  /// Whether the whole day index may lay out the Timeline up front, which is
  /// only true while nothing narrows or reorders it.
  bool get showsFullTimeline =>
      filter == MediaFilter.all &&
      query.isEmpty &&
      sort == LibrarySort.newest &&
      subfolder == null;

  /// Leaves search, selection, filter and sub-folder behind. The expanded
  /// Albums section is kept when [keepAlbumSection] is set, such as when
  /// opening an album from it.
  void reset({bool keepAlbumSection = false}) {
    selected.clear();
    query = '';
    searching = false;
    if (!keepAlbumSection) {
      showPeople = false;
      albumsExpanded = false;
    }
    filter = MediaFilter.all;
    subfolder = null;
  }

  /// Opens or closes search; closing clears the text.
  void toggleSearch() {
    searching = !searching;
    if (!searching) query = '';
  }

  /// Selects or deselects [file]; read-only files cannot be selected.
  void toggle(CloudFile file) {
    if (file.readOnly) return;
    if (selected.remove(file.key) == null) selected[file.key] = file;
  }

  /// Selects every selectable file of a group, or clears them when [all] are
  /// already selected.
  void toggleAll(Iterable<CloudFile> files, bool all) {
    for (final file in files.where((f) => !f.readOnly)) {
      if (all) {
        selected.remove(file.key);
      } else {
        selected[file.key] = file;
      }
    }
  }

  /// [items] as this view shows them. The result is reused until the items or
  /// a setting that changes it does.
  List<CloudFile> visibleFiles(
    List<CloudFile> items, {
    required bool drive,
    required bool collection,
  }) {
    final key = (items, query, subfolder, filter, sort, drive, collection);
    if (key == _visibleKey) return _visibleFiles;
    _visibleKey = key;
    return _visibleFiles = filterAndSortFiles(
      items,
      query: query,
      subfolder: subfolder,
      filter: filter,
      sort: sort,
      drive: drive,
      collection: collection,
    );
  }
}

/// One remembered result and the inputs it was made from.
class MemoSlot {
  Object? key;
  Object? value;
}
