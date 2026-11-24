import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/adaptive_limit.dart';
import 'package:ncloud/features/backup/engine/sync_engine.dart';

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
          await limit.acquire(1);
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
        limit.release(1);
      }
      await drive(limit, 5, (n) => n * 1000.0);
      expect(limit.limit, before ~/ 2);
    });

    test('never goes below one', () {
      final limit = make();
      for (var i = 0; i < 5; i++) {
        limit.struggled();
      }
      expect(limit.limit, 1);
    });

    test(
      'never starts above the number of uploads it is told to start with',
      () {
        expect(AdaptiveLimit(start: 3, max: 1).max, 3);
        expect(AdaptiveLimit(start: 3, max: 64).max, 8);
      },
    );

    test('keeps the staged bytes in flight under the budget', () async {
      final limit = AdaptiveLimit(start: 3, max: 8, byteBudget: 100);
      var running = 0;
      var peak = 0;
      var peakBytes = 0;
      var bytesNow = 0;
      await runConcurrently(
        List.generate(12, (i) => 40),
        8,
        (size) async {
          running++;
          bytesNow += size;
          peak = running > peak ? running : peak;
          peakBytes = bytesNow > peakBytes ? bytesNow : peakBytes;
          await Future<void>.delayed(const Duration(milliseconds: 2));
          running--;
          bytesNow -= size;
        },
        limit: limit,
        sizeOf: (size) => size,
      );
      expect(peakBytes, lessThanOrEqualTo(100));
      expect(peak, 2);
    });

    test('always lets one file through, however large', () async {
      final limit = AdaptiveLimit(start: 3, max: 8, byteBudget: 10);
      var done = 0;
      await runConcurrently(
        [1000, 1000, 1000],
        8,
        (size) async => done++,
        limit: limit,
        sizeOf: (size) => size,
      );
      expect(done, 3);
    });

    test('never runs more at once than the limit', () async {
      final limit = AdaptiveLimit(start: 3, max: 8);
      var running = 0;
      var peak = 0;
      await runConcurrently(
        List.generate(40, (i) => i),
        8,
        (item) async {
          running++;
          peak = running > peak ? running : peak;
          await Future<void>.delayed(const Duration(milliseconds: 1));
          running--;
        },
        limit: limit,
        sizeOf: (item) => 1,
      );
      expect(peak, 3);
    });
  });
}
