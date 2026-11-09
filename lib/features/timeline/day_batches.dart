import '../../models.dart';

/// Picks days from [candidates], in order, until the request would hold more
/// than [limit] photos or [maxDays] days. A single day is always taken, however
/// large, so a huge day cannot starve.
List<int> chooseDayBatch(
  Iterable<TimelineDay> candidates, {
  required int limit,
  int maxDays = 120,
}) {
  final ids = <int>[];
  var count = 0;
  for (final day in candidates) {
    if (ids.length >= maxDays ||
        (ids.isNotEmpty && count + day.count > limit)) {
      break;
    }
    ids.add(day.id);
    count += day.count;
  }
  return ids;
}

/// The days the scrolling Timeline asked for. The most recent request loads
/// first, and requests left far behind by a fast scrub are dropped.
class DayRequestQueue {
  DayRequestQueue({this.capacity = 60});

  final int capacity;
  final Set<int> _days = {};

  bool get isEmpty => _days.isEmpty;
  bool get isNotEmpty => _days.isNotEmpty;

  void request(int day) {
    _days
      ..remove(day)
      ..add(day);
    while (_days.length > capacity) {
      _days.remove(_days.first);
    }
  }

  void clear() => _days.clear();

  /// Removes and returns the next days to fetch. Days the index does not know
  /// or that [needed] rejects are discarded.
  List<int> takeBatch({
    required Map<int, int> counts,
    required bool Function(int day) needed,
    required int limit,
  }) {
    final candidates = <TimelineDay>[];
    for (final day in _days.toList().reversed) {
      final size = counts[day];
      if (size == null || !needed(day)) {
        _days.remove(day);
      } else {
        candidates.add(TimelineDay(day, size));
      }
    }
    final batch = chooseDayBatch(candidates, limit: limit);
    _days.removeAll(batch);
    return batch;
  }
}
