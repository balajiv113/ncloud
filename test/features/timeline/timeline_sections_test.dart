import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/timeline/timeline_sections.dart';
import 'package:ncloud/models.dart';

CloudFile photo(
  String name, {
  int? day,
  DateTime? taken,
  bool favorite = false,
}) => CloudFile(
  path: ['Photos', name],
  name: name,
  isDirectory: false,
  contentType: 'image/jpeg',
  captureDay: day,
  taken: taken,
  favorite: favorite,
);

String dayLabel(DateTime? date) =>
    date == null ? 'unknown' : '${date.year}-${date.month}-${date.day}';

void main() {
  int dayId(DateTime date) =>
      DateTime.utc(date.year, date.month, date.day).millisecondsSinceEpoch ~/
      86400000;

  final first = dayId(DateTime(2024, 5, 2));
  final second = dayId(DateTime(2024, 5, 1));

  List<TimelineSection> build(
    List<CloudFile> media, {
    List<TimelineDay>? days,
    Set<int> loaded = const {},
    Set<int> stale = const {},
  }) => buildTimelineSections(
    media: media,
    indexedDays: days,
    dayLoaded: loaded.contains,
    dayNeedsRefresh: stale.contains,
    labelFor: dayLabel,
  );

  test(
    'labels read Today, Yesterday, a date, or only the month when dense',
    () {
      final now = DateTime(2024, 5, 10, 15);
      String label(DateTime? date, {bool byMonth = false}) => timelineLabel(
        date,
        byMonth: byMonth,
        formatMonth: (d) => 'M${d.month}',
        formatDate: (d) => 'D${d.day}',
        now: now,
      );
      expect(label(DateTime(2024, 5, 10, 1)), 'Today');
      expect(label(DateTime(2024, 5, 9)), 'Yesterday');
      expect(label(DateTime(2024, 5, 3)), 'D3');
      expect(label(DateTime(2024, 5, 10), byMonth: true), 'M5');
      expect(label(null), 'Date unavailable');
    },
  );

  test('every indexed day gets a section sized from its count', () {
    final sections = build(
      [photo('a.jpg', day: first)],
      days: [TimelineDay(first, 3), TimelineDay(second, 5)],
    );
    expect([for (final s in sections) s.label], ['2024-5-2', '2024-5-1']);
    expect([for (final s in sections) s.expected], [3, 5]);
    expect(sections.first.files, hasLength(1));
    expect(sections.first.pending, [first]);
    expect(sections.last.pending, [second]);
  });

  test('a loaded day expects exactly the photos it holds', () {
    final sections = build(
      [photo('a.jpg', day: first), photo('b.jpg', day: first)],
      days: [TimelineDay(first, 9)],
      loaded: {first},
    );
    expect(sections.single.expected, 2);
    expect(sections.single.pending, isEmpty);
  });

  test('a loaded day that changed is queued again but keeps its photos', () {
    final sections = build(
      [photo('a.jpg', day: first)],
      days: [TimelineDay(first, 1)],
      loaded: {first},
      stale: {first},
    );
    expect(sections.single.pending, [first]);
    expect(sections.single.files, hasLength(1));
  });

  test('empty days are dropped and undated photos follow the index', () {
    final sections = build(
      [photo('a.jpg', day: first), photo('b.jpg', taken: DateTime(2020, 1, 1))],
      days: [TimelineDay(first, 1), TimelineDay(second, 0)],
    );
    expect([for (final s in sections) s.label], ['2024-5-2', '2020-1-1']);
  });

  test('without an index, neighbours with the same label share a section', () {
    final sections = build([
      photo('a.jpg', taken: DateTime(2024, 5, 2, 9)),
      photo('b.jpg', taken: DateTime(2024, 5, 2, 18)),
      photo('c.jpg', taken: DateTime(2024, 5, 1)),
    ]);
    expect([for (final s in sections) s.files.length], [2, 1]);
    expect([for (final s in sections) s.expected], [2, 1]);
  });

  test('memories group today\'s date in past years and add favorites', () {
    final now = DateTime(2024, 5, 2);
    final groups = memoryGroups([
      photo('one.jpg', taken: DateTime(2023, 5, 2)),
      photo('two.jpg', taken: DateTime(2021, 5, 2), favorite: true),
      photo('other.jpg', taken: DateTime(2023, 6, 2)),
      photo('now.jpg', taken: DateTime(2024, 5, 2)),
    ], now: now);
    expect(groups.keys, ['1 year ago', '3 years ago', 'A few favorites']);
    expect([for (final f in groups['A few favorites']!) f.name], ['two.jpg']);
    expect(
      memoryGroups([photo('x.jpg', taken: DateTime(2023, 1, 1))], now: now),
      isEmpty,
    );
  });

  group('tracker', () {
    final tracker = TimelineTracker()
      ..start = 100
      ..stops.addAll([
        (offset: 0, label: 'a', date: DateTime(2024, 5, 2)),
        (offset: 400, label: 'b', date: DateTime(2023, 12, 1)),
        (offset: 900, label: 'c', date: null),
      ])
      ..rows.addAll([
        (offset: 44, files: [photo('a.jpg'), photo('b.jpg')]),
        (offset: 300, files: [photo('c.jpg')]),
        (offset: 444, files: [photo('d.jpg')]),
      ]);
    String month(DateTime d) => '${d.year}-${d.month}';

    test('names the month under a scroll offset', () {
      expect(tracker.labelAt(0, month), '2024-5');
      expect(tracker.labelAt(500, month), '2023-12');
      expect(tracker.labelAt(1100, month), '2023-12');
    });

    test('lists a marker for each new year', () {
      expect(tracker.yearMarkers(), [
        (offset: 100.0, label: '2024'),
        (offset: 500.0, label: '2023'),
      ]);
    });

    test('anchors to the top row and finds its offset again', () {
      expect(tracker.anchorAt(50), isNull);
      expect(tracker.anchorAt(100 + 320), 'Photos/c.jpg');
      expect(tracker.offsetOf('Photos/d.jpg'), 544);
      expect(tracker.offsetOf('Photos/zzz.jpg'), isNull);
    });
  });
}
