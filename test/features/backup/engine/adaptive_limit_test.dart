import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/adaptive_limit.dart';

void main() {
  group('AdaptiveLimit', () {
    late DateTime now;
    AdaptiveLimit make({int max = 8}) =>
        AdaptiveLimit(start: 3, max: max, clock: () => now);

    /// Runs [windows] of 20 seconds on a link that carries [rateAt] bytes a
    /// second with a given number of uploads.
    Future<void> drive(
      AdaptiveLimit limit,
      int windows,
      double Function(int uploads) rateAt,
    ) async {
      for (var w = 0; w < windows; w++) {
        while (limit.active < limit.limit) {
          await limit.acquire();
        }
        final bytes = (rateAt(limit.limit) * 20).round();
        now = now.add(const Duration(seconds: 20));
        limit.sent(bytes);
      }
    }

    setUp(() => now = DateTime(2025));

    test(
      'climbs while more uploads help and stops at the device maximum',
      () async {
        final limit = make(max: 6);
        await drive(limit, 12, (n) => n * 1000.0);
        expect(limit.limit, 6);
      },
    );

    test('settles where the link is full and does not run away', () async {
      final limit = make();
      // The link carries 4,000 a second however many uploads there are.
      await drive(limit, 40, (n) => n >= 4 ? 4000.0 : n * 1000.0);
      expect(limit.limit, inInclusiveRange(4, 5));
    });

    test(
      'does not climb past the start on a link that is full already',
      () async {
        final limit = make();
        await drive(limit, 20, (n) => 3000.0);
        expect(limit.limit, lessThanOrEqualTo(4));
      },
    );

    test('halves on a transient failure and stays calm for a while', () async {
      final limit = make();
      await drive(limit, 12, (n) => n * 1000.0);
      expect(limit.limit, greaterThan(4));
      final before = limit.limit;
      limit.struggled();
      expect(limit.limit, before ~/ 2);
      while (limit.active > 0) {
        limit.release();
      }
      await drive(limit, 5, (n) => n * 1000.0);
      expect(limit.limit, before ~/ 2);
    });

    test(
      'never goes below two, so one slow upload cannot hold up the rest',
      () {
        final limit = make();
        for (var i = 0; i < 5; i++) {
          limit.struggled();
        }
        expect(limit.limit, 2);
      },
    );

    test(
      'never starts above the number of uploads it is told to start with',
      () {
        expect(AdaptiveLimit(start: 3, max: 1).max, 3);
        expect(AdaptiveLimit(start: 3, max: 64).max, 8);
      },
    );

    test('waits for a free place and never runs more than the limit', () async {
      final limit = make();
      var running = 0;
      var peak = 0;
      Future<void> one() async {
        await limit.acquire();
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        running--;
        limit.release();
      }

      await Future.wait(List.generate(40, (_) => one()));
      expect(peak, 3);
      expect(limit.active, 0);
    });
  });

  group('Gate', () {
    test('lets only its size through at once', () async {
      final gate = Gate(2);
      var running = 0;
      var peak = 0;
      Future<void> one() async {
        await gate.acquire();
        running++;
        peak = running > peak ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        running--;
        gate.release();
      }

      await Future.wait(List.generate(10, (_) => one()));
      expect(peak, 2);
    });
  });

  group('ByteBudget', () {
    test(
      'lets one file through however large and holds the rest back',
      () async {
        final budget = ByteBudget(100);
        await budget.acquire(1000);
        var second = false;
        final waiting = budget.acquire(10).then((_) => second = true);
        await Future<void>.delayed(const Duration(milliseconds: 5));
        expect(second, isFalse);
        budget.release(1000);
        await waiting;
        expect(second, isTrue);
      },
    );

    test('keeps admitting while under the budget', () async {
      final budget = ByteBudget(100);
      await budget.acquire(40);
      await budget.acquire(40);
      await budget.acquire(40);
    });
  });
}
