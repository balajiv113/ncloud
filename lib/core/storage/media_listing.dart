import 'file_store.dart';
import '../../models.dart';

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
