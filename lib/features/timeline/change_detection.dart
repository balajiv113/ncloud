import '../../models.dart';

/// How long the day index may go unchecked while nothing else signals a
/// change.
const indexSweepInterval = Duration(minutes: 15);

/// Files a push notification said changed, kept until a check can use them.
/// Unknown ids mean any file may have changed.
class ChangeHints {
  bool _pending = false;
  Set<String>? _ids = {};

  void add(Set<String>? ids) {
    _pending = true;
    if (ids == null) {
      _ids = null;
    } else {
      _ids?.addAll(ids);
    }
  }

  /// The pending hints, now consumed, or null when there are none. The ids are
  /// null when the changed files are unknown.
  ({Set<String>? ids})? take() {
    if (!_pending) return null;
    final taken = (ids: _ids);
    clear();
    return taken;
  }

  void clear() {
    _pending = false;
    _ids = {};
  }
}

/// What a change check must do.
class ChangePlan {
  const ChangePlan({
    required this.treeChanged,
    required this.metadataSweep,
    required this.idle,
  });

  /// Files were added, removed or edited since the last check.
  final bool treeChanged;

  /// Nothing changed, but it has been long enough that metadata edits, which
  /// do not change the tree's revision, may have been missed.
  final bool metadataSweep;

  /// The tree is the one last seen and the index was compared recently, so
  /// there is nothing to do.
  final bool idle;

  /// Whether anything on screen may be out of date.
  bool get stale => treeChanged || metadataSweep;
}

/// Decides what a check must do from the tree [etag] now, the one seen last
/// time, and when the day index was last compared. [force] means a push
/// notification already says something changed. The first check after
/// starting always compares the index, because no revision was seen yet.
ChangePlan planCheck({
  required bool force,
  required String? etag,
  required String? knownEtag,
  required DateTime? lastIndexCheck,
  required DateTime now,
}) {
  final treeChanged =
      force || (etag != null && knownEtag != null && etag != knownEtag);
  final indexDue =
      lastIndexCheck == null ||
      now.difference(lastIndexCheck) >= indexSweepInterval;
  return ChangePlan(
    treeChanged: treeChanged,
    metadataSweep: indexDue && lastIndexCheck != null,
    idle: !treeChanged && etag != null && etag == knownEtag && !indexDue,
  );
}

/// The days whose photos may have changed, given the file ids a push named and
/// the files already [known]. Null means any day may have: the ids are unknown,
/// some name files not seen before, or a known file has no capture day.
Set<int>? hintedDays(Set<String>? ids, Iterable<CloudFile> known) {
  if (ids == null || ids.isEmpty) return null;
  final named = known.where((file) => ids.contains(file.id)).toList();
  final knownIds = named.map((file) => file.id).toSet();
  if (!ids.every(knownIds.contains) ||
      named.any((file) => file.captureDay == null)) {
    return null;
  }
  return {for (final file in named) file.captureDay!};
}

/// Days whose photo count differs between two indexes, and how many photos
/// were added overall.
class DayChanges {
  const DayChanges(this.days, this.added);

  final Set<int> days;
  final int added;
}

DayChanges? diffDays(List<TimelineDay> before, List<TimelineDay> after) {
  final was = {for (final day in before) day.id: day.count};
  final now = {for (final day in after) day.id: day.count};
  final changed = {
    for (final id in {...was.keys, ...now.keys})
      if (was[id] != now[id]) id,
  };
  if (changed.isEmpty) return null;
  int total(Map<int, int> counts) => counts.values.fold(0, (a, b) => a + b);
  final added = total(now) - total(was);
  return DayChanges(changed, added < 0 ? 0 : added);
}
