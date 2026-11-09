import '../../models.dart';

/// One dated group of photos in the Timeline: its header, the photos loaded so
/// far and how many it is expected to hold once its day has loaded.
class TimelineSection {
  TimelineSection({required this.label, required this.date});

  final String label;
  final DateTime? date;
  final List<CloudFile> files = [];

  /// Indexed days whose photos still need loading or refreshing.
  final List<int> pending = [];
  int expected = 0;
}

/// Header text for a section dated [date]: "Today" and "Yesterday", the date,
/// or only the month when the grid is dense ([byMonth]).
String timelineLabel(
  DateTime? date, {
  required bool byMonth,
  required String Function(DateTime date) formatMonth,
  required String Function(DateTime date) formatDate,
  DateTime? now,
}) {
  if (date == null) return 'Date unavailable';
  if (byMonth) return formatMonth(date);
  now ??= DateTime.now();
  final day = DateTime(date.year, date.month, date.day);
  final today = DateTime(now.year, now.month, now.day);
  if (day == today) return 'Today';
  if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
  return formatDate(date);
}

/// Groups [media] into dated sections, newest first as given.
///
/// With [indexedDays] every day of the index gets a section sized from its
/// photo count, so the whole Timeline can be laid out before its photos load;
/// photos without an indexed day follow. Without it, sections are formed from
/// the loaded photos alone. Consecutive photos with the same [labelFor] share
/// a section, and sections that expect nothing are dropped.
List<TimelineSection> buildTimelineSections({
  required List<CloudFile> media,
  List<TimelineDay>? indexedDays,
  required bool Function(int day) dayLoaded,
  required bool Function(int day) dayNeedsRefresh,
  required String Function(DateTime? date) labelFor,
}) {
  final sections = <TimelineSection>[];
  void add(DateTime? date, List<CloudFile> files, int expected, int? pending) {
    final label = labelFor(date);
    var section = sections.lastOrNull;
    if (section == null || section.label != label) {
      section = TimelineSection(label: label, date: date);
      sections.add(section);
    }
    section.files.addAll(files);
    section.expected += expected;
    if (pending != null) section.pending.add(pending);
  }

  if (indexedDays != null) {
    final byDay = <int, List<CloudFile>>{};
    final other = <CloudFile>[];
    for (final file in media) {
      if (file.captureDay case final day?) {
        byDay.putIfAbsent(day, () => []).add(file);
      } else {
        other.add(file);
      }
    }
    for (final day in indexedDays) {
      final utc = DateTime.fromMillisecondsSinceEpoch(
        day.id * 86400000,
        isUtc: true,
      );
      final loaded = dayLoaded(day.id);
      final found = byDay.remove(day.id) ?? [];
      add(
        DateTime(utc.year, utc.month, utc.day),
        found,
        loaded
            ? found.length
            : (day.count > found.length ? day.count : found.length),
        loaded && !dayNeedsRefresh(day.id) ? null : day.id,
      );
    }
    for (final file in [...byDay.values.expand((f) => f), ...other]) {
      add(file.timelineDate?.toLocal(), [file], 1, null);
    }
  } else {
    for (final file in media) {
      add(file.timelineDate?.toLocal(), [file], 1, null);
    }
  }
  return sections.where((s) => s.expected > 0).toList();
}

/// "N years ago" groups of photos taken on today's date in earlier years,
/// followed by one "A few favorites" group.
Map<String, List<CloudFile>> memoryGroups(
  List<CloudFile> files, {
  DateTime? now,
}) {
  now ??= DateTime.now();
  final result = <String, List<CloudFile>>{};
  for (final file in files) {
    final date = file.timelineDate?.toLocal();
    if (!file.isMedia || date == null || date.year >= now.year) continue;
    if (date.month == now.month && date.day == now.day) {
      final years = now.year - date.year;
      result
          .putIfAbsent(years == 1 ? '1 year ago' : '$years years ago', () => [])
          .add(file);
    }
  }
  final favorites = files.where((f) => f.isMedia && f.favorite).toList();
  if (favorites.isNotEmpty) result['A few favorites'] = favorites;
  return result;
}

/// Where the Timeline's sections and photo rows sit, recorded while it lays
/// out, so the scrubber can name the date under its handle and a density
/// change can keep the photo row at the top of the screen in view.
class TimelineTracker {
  final List<({double offset, String label, DateTime? date})> stops = [];
  final List<({double offset, List<CloudFile> files})> rows = [];

  /// Scroll extent above the Timeline, such as the header and banners.
  double start = 0;

  void clear() {
    stops.clear();
    rows.clear();
  }

  /// Month shown in the scrubber bubble for a scroll [offset].
  String? labelAt(double offset, String Function(DateTime date) formatMonth) {
    DateTime? date;
    for (final stop in stops) {
      if (stop.offset > offset - start + 56) break;
      date = stop.date ?? date;
    }
    date ??= stops.firstOrNull?.date;
    return date == null ? null : formatMonth(date);
  }

  /// Year markers shown beside the scrubber track while dragging.
  List<({double offset, String label})> yearMarkers() {
    final markers = <({double offset, String label})>[];
    int? year;
    for (final stop in stops) {
      final date = stop.date;
      if (date == null || date.year == year) continue;
      year = date.year;
      markers.add((offset: start + stop.offset, label: '$year'));
    }
    return markers;
  }

  /// Key of the first photo in the row at the top of a viewport scrolled to
  /// [scrollOffset], or null while the Timeline itself is not yet reached.
  String? anchorAt(double scrollOffset) {
    if (scrollOffset <= start) return null;
    String? anchor;
    for (final row in rows) {
      if (row.offset > scrollOffset - start) break;
      anchor = row.files.first.key;
    }
    return anchor;
  }

  /// Scroll offset of the row holding the photo with [key], once laid out.
  double? offsetOf(String key) {
    final row = rows.where((r) => r.files.any((f) => f.key == key)).firstOrNull;
    return row == null ? null : start + row.offset;
  }
}
