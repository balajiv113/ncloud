import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/timeline/change_detection.dart';
import 'package:ncloud/features/timeline/day_batches.dart';
import 'package:ncloud/models.dart';

void main() {
  group('ChangeHints', () {
    test('is empty until a hint is added, and taking consumes it', () {
      final hints = ChangeHints();
      expect(hints.take(), isNull);
      hints.add({'1'});
      hints.add({'2'});
      expect(hints.take()!.ids, {'1', '2'});
      expect(hints.take(), isNull);
    });

    test('unknown ids win over known ones', () {
      final hints = ChangeHints()
        ..add({'1'})
        ..add(null)
        ..add({'2'});
      expect(hints.take()!.ids, isNull);
    });

    test('clear forgets everything', () {
      final hints = ChangeHints()..add({'1'});
      hints.clear();
      expect(hints.take(), isNull);
    });
  });

  group('planCheck', () {
    final now = DateTime(2024, 5, 1, 12);
    ChangePlan plan({
      bool force = false,
      String? etag = 'b',
      String? known = 'a',
      DateTime? last,
    }) => planCheck(
      force: force,
      etag: etag,
      knownEtag: known,
      lastIndexCheck: last,
      now: now,
    );

    test('a different tree revision means the tree changed', () {
      expect(plan(last: now).treeChanged, isTrue);
      expect(plan(last: now).idle, isFalse);
    });

    test('the same revision shortly after a comparison is idle', () {
      final p = plan(etag: 'a', last: now.subtract(const Duration(minutes: 1)));
      expect(p.idle, isTrue);
      expect(p.stale, isFalse);
    });

    test('an unchanged tree is swept for metadata edits after 15 minutes', () {
      final p = plan(
        etag: 'a',
        last: now.subtract(const Duration(minutes: 20)),
      );
      expect(p.treeChanged, isFalse);
      expect(p.metadataSweep, isTrue);
      expect(p.idle, isFalse);
    });

    test('the first check always compares the index', () {
      final p = plan(etag: 'a');
      expect(p.idle, isFalse);
      expect(p.metadataSweep, isFalse);
    });

    test('a push forces a change even with the same revision', () {
      expect(plan(force: true, etag: 'a', last: now).treeChanged, isTrue);
    });

    test('an unknown revision is not a change by itself', () {
      expect(plan(etag: null, known: null, last: now).treeChanged, isFalse);
    });
  });

  group('hintedDays', () {
    CloudFile file(String id, int? day) => CloudFile(
      path: ['p$id.jpg'],
      name: 'p$id.jpg',
      isDirectory: false,
      id: id,
      captureDay: day,
    );

    test('names the days of known files', () {
      expect(
        hintedDays({'1', '2'}, [file('1', 10), file('2', 11), file('3', 12)]),
        {10, 11},
      );
    });

    test('is null when ids are unknown, unseen or undated', () {
      final known = [file('1', 10), file('2', null)];
      expect(hintedDays(null, known), isNull);
      expect(hintedDays({}, known), isNull);
      expect(hintedDays({'1', '9'}, known), isNull);
      expect(hintedDays({'2'}, known), isNull);
    });
  });

  group('diffDays', () {
    test('is null when nothing changed', () {
      expect(
        diffDays(const [TimelineDay(1, 2)], const [TimelineDay(1, 2)]),
        isNull,
      );
    });

    test('finds changed, new and removed days and counts additions', () {
      final changes = diffDays(
        const [TimelineDay(3, 2), TimelineDay(2, 5), TimelineDay(1, 1)],
        const [TimelineDay(4, 3), TimelineDay(3, 4), TimelineDay(1, 1)],
      )!;
      expect(changes.days, {4, 3, 2});
      expect(changes.added, 0);
    });

    test('reports how many photos were added', () {
      final changes = diffDays(
        const [TimelineDay(1, 1)],
        const [TimelineDay(1, 1), TimelineDay(2, 4)],
      )!;
      expect(changes.added, 4);
    });
  });

  group('day batches', () {
    test('stops before the photo limit but always takes one day', () {
      const days = [
        TimelineDay(5, 100),
        TimelineDay(4, 100),
        TimelineDay(3, 100),
      ];
      expect(chooseDayBatch(days, limit: 250), [5, 4]);
      expect(chooseDayBatch(days, limit: 50), [5]);
      expect(chooseDayBatch(days, limit: 1000, maxDays: 2), [5, 4]);
    });

    test('the queue serves the latest request first and drops the oldest', () {
      final queue = DayRequestQueue(capacity: 3);
      for (final day in [1, 2, 3, 4]) {
        queue.request(day);
      }
      final batch = queue.takeBatch(
        counts: {for (var d = 1; d <= 4; d++) d: 10},
        needed: (_) => true,
        limit: 25,
      );
      expect(batch, [4, 3]);
      expect(queue.isEmpty, isFalse);
    });

    test('days that are unknown or no longer needed are discarded', () {
      final queue = DayRequestQueue()
        ..request(1)
        ..request(2)
        ..request(3);
      final batch = queue.takeBatch(
        counts: {1: 10, 3: 10},
        needed: (day) => day != 3,
        limit: 100,
      );
      expect(batch, [1]);
      expect(queue.isEmpty, isTrue);
    });
  });
}
