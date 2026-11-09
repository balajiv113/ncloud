import 'file_store.dart';
import '../../models.dart';

/// A batch fetched for a listing: the files of whole [days] when the view is
/// indexed, or the next page and its [nextCursor] when it is not.
class FetchedPage {
  const FetchedPage(this.files, {this.days = const [], this.nextCursor});

  final List<CloudFile> files;
  final List<int> days;
  final String? nextCursor;
}

/// A view's ordered references into the shared [FileStore] plus its paging
/// state; files themselves are never duplicated per view.
class MediaListing {
  List<String> keys = [];
  final Set<String> _known = {};
  List<TimelineDay>? days;
  final Set<int> loaded = {};
  final Set<int> staleDays = {};
  bool allowCachedDays = true;
  String? cursor;
  String? scopeEtag;
  bool more = false;
  DateTime updated = DateTime.now();

  bool fresh(FileStore store) =>
      !updated.isBefore(store.staleBefore) &&
      DateTime.now().difference(updated) < const Duration(minutes: 5);

  void add(FileStore store, List<CloudFile> files) {
    store.putAll(files);
    for (final file in files) {
      if (_known.add(file.key)) keys.add(file.key);
    }
  }

  List<CloudFile>? _resolved;
  Object? _resolvedKeys;
  int _resolvedLength = -1;
  int _resolvedRevision = -1;

  /// The listing's files. The same list is returned while the membership and
  /// the store are unchanged, so views that remember work done on it, such as
  /// sorting and grouping, can reuse it when the listing is shown again.
  List<CloudFile> resolve(FileStore store) {
    if (_resolved == null ||
        !identical(_resolvedKeys, keys) ||
        _resolvedLength != keys.length ||
        _resolvedRevision != store.revision) {
      _resolved = store.resolve(keys);
      _resolvedKeys = keys;
      _resolvedLength = keys.length;
      _resolvedRevision = store.revision;
    }
    return _resolved!;
  }

  /// Adds a fetched batch. Days it covers are replaced wholesale, so photos
  /// the server no longer has leave the listing; those are returned.
  Set<String> merge(FileStore store, FetchedPage page) {
    var gone = <String>{};
    if (page.days.isNotEmpty) {
      final replaced = page.days.toSet();
      final previous = {
        for (final key in keys)
          if (replaced.contains(store[key]?.captureDay)) key,
      };
      final returned = page.files.map((file) => file.key).toSet();
      gone = previous.difference(returned);
      replace(const {}, previous);
      staleDays.removeAll(replaced);
    }
    add(store, page.files);
    if (days case final days?) {
      loaded.addAll(page.days);
      more = days.any((d) => !loaded.contains(d.id));
    } else {
      cursor = page.nextCursor;
      more = page.nextCursor != null;
    }
    return gone;
  }

  /// Marks loaded days as needing a refresh: those in [only], or all of them.
  void markStale({Set<int>? only}) =>
      staleDays.addAll(only == null ? loaded : loaded.where(only.contains));

  /// Adopts a newer day index after [changed] days differ. Days the server no
  /// longer has are dropped; the others are marked stale. Returns the days that
  /// were on screen and must be fetched again.
  List<int> applyIndex(
    FileStore store,
    List<TimelineDay> newDays,
    Set<int> changed,
  ) {
    final present = {for (final day in newDays) day.id};
    final reload = changed.where(
      (d) => loaded.contains(d) && present.contains(d),
    );
    final removed = changed.difference(present);
    staleDays.addAll(changed);
    loaded.removeAll(removed);
    staleDays.removeAll(removed);
    replace(const {}, {
      for (final key in keys)
        if (removed.contains(store[key]?.captureDay)) key,
    });
    days = newDays;
    more = newDays.any((d) => !loaded.contains(d.id));
    updated = DateTime.now();
    return reload.toList();
  }

  /// Eviction must not leave a day marked as loaded with missing photo rows.
  void pruneEvicted(FileStore store) {
    final missing = keys.where((key) => store[key] == null).toSet();
    if (missing.isEmpty) return;
    keys.removeWhere(missing.contains);
    _known.removeAll(missing);
    final counts = <int, int>{};
    for (final key in keys) {
      final day = store[key]?.captureDay;
      if (day != null) counts[day] = (counts[day] ?? 0) + 1;
    }
    for (final day in days ?? <TimelineDay>[]) {
      if (counts[day.id] != day.count) loaded.remove(day.id);
    }
    if (days case final days?) {
      more = days.any((day) => !loaded.contains(day.id));
    }
  }

  /// Swaps placeholder keys for resolved files, dropping any in [gone].
  bool replace(Map<String, String> renamed, Set<String> gone) {
    if (!keys.any((k) => renamed.containsKey(k) || gone.contains(k))) {
      return false;
    }
    final next = <String>[];
    _known.clear();
    for (final key in keys) {
      if (gone.contains(key)) continue;
      final value = renamed[key] ?? key;
      if (_known.add(value)) next.add(value);
    }
    keys = next;
    return true;
  }

  Map<String, dynamic> toJson() => {
    'keys': keys,
    'days': days?.map((d) => d.toJson()).toList(),
    'loaded': loaded.toList(),
    'staleDays': staleDays.toList(),
    'cursor': cursor,
    'scopeEtag': scopeEtag,
    'more': more,
    'updated': updated.toIso8601String(),
  };

  static MediaListing fromJson(Map<String, dynamic> value) {
    final listing = MediaListing()
      ..days = (value['days'] as List?)
          ?.map((d) => TimelineDay.fromJson((d as Map).cast<String, dynamic>()))
          .toList()
      ..cursor = value['cursor'] as String?
      ..scopeEtag = value['scopeEtag'] as String?
      ..more = value['more'] as bool
      ..updated = DateTime.parse(value['updated'] as String);
    listing.keys = (value['keys'] as List).cast<String>();
    listing._known.addAll(listing.keys);
    listing.loaded.addAll((value['loaded'] as List).cast<int>());
    listing.staleDays.addAll((value['staleDays'] as List).cast<int>());
    return listing;
  }
}
