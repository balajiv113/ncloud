import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/timeline_layout.dart';

void main() {
  test('large date indexes keep random timeline lookups bounded', () {
    final layout = TimelineGridLayout(
      counts: List.filled(100000, 100),
      columns: 3,
      tileExtent: 100,
      headerExtent: 44,
    );
    expect(layout.itemCount, 10100000);
    expect(layout.starts, hasLength(100000));
    final watch = Stopwatch()..start();
    for (var i = 0; i < 10000; i++) {
      final section = (i * 7919) % layout.starts.length;
      final index = layout.starts[section] + 1;
      final geometry = layout.getGeometryForChildIndex(index);
      expect(layout.sectionForIndex(index), section);
      expect(
        layout.getMinChildIndexForScrollOffset(geometry.scrollOffset),
        index,
      );
    }
    watch.stop();
    expect(
      watch.elapsed,
      lessThan(const Duration(seconds: 10)),
      reason: 'Random date lookup must not scan the photo/date collection.',
    );
    debugPrint(
      'Timeline: 10,000 random lookups over 100,000 days in '
      '${watch.elapsedMilliseconds} ms.',
    );
  });

  testWidgets(
    'a million photos build only viewport tiles, including after a jump',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      final layout = TimelineGridLayout(
        counts: List.filled(1000, 1000),
        columns: 3,
        tileExtent: 100,
        headerExtent: 44,
      );
      final built = <int>[];
      await tester.pumpWidget(
        MaterialApp(
          home: CustomScrollView(
            controller: controller,
            slivers: [
              SliverGrid(
                gridDelegate: TimelineGridDelegate(layout),
                delegate: SliverChildBuilderDelegate((context, index) {
                  built.add(index);
                  return const SizedBox.expand();
                }, childCount: layout.itemCount),
              ),
            ],
          ),
        ),
      );
      expect(built.length, lessThan(100));
      built.clear();
      controller.jumpTo(layout.scrollExtent * .95);
      await tester.pump();
      expect(built.length, lessThan(100));
      expect(built, isNotEmpty);
      expect(built.first, greaterThan(900000));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('date headers and partial photo rows have exact offsets', () {
    final layout = TimelineGridLayout(
      counts: [5, 1],
      columns: 3,
      tileExtent: 100,
      headerExtent: 44,
    );
    expect(layout.starts, [0, 6]);
    expect(layout.offsets, [0, 248]);
    expect(layout.itemCount, 8);
    expect(layout.computeMaxScrollOffset(8), 394);
    final header = layout.getGeometryForChildIndex(6);
    expect(header.scrollOffset, 248);
    expect(header.crossAxisExtent, 304);
    final tile = layout.getGeometryForChildIndex(5);
    expect(tile.scrollOffset, 146);
    expect(tile.crossAxisOffset, 102);
    expect(layout.getMinChildIndexForScrollOffset(44), 1);
    expect(layout.getMaxChildIndexForScrollOffset(44), 0);
    expect(layout.getMaxChildIndexForScrollOffset(146), 3);
    expect(layout.getMinChildIndexForScrollOffset(248), 6);
    expect(layout.getMaxChildIndexForScrollOffset(248), 5);
    expect(layout.getMinChildIndexForScrollOffset(292), 7);
    expect(layout.getMaxChildIndexForScrollOffset(394), 7);
  });

  test(
    'million-photo layout stores only date boundaries and jumps directly',
    () {
      final layout = TimelineGridLayout(
        counts: List.filled(1000, 1000),
        columns: 3,
        tileExtent: 100,
        headerExtent: 44,
      );
      expect(layout.itemCount, 1001000);
      expect(layout.offsets, hasLength(1000));
      expect(layout.starts, hasLength(1000));
      for (final section in [0, 500, 999]) {
        final index = layout.starts[section] + 997;
        final geometry = layout.getGeometryForChildIndex(index);
        expect(layout.sectionForIndex(index), section);
        expect(
          layout.getMinChildIndexForScrollOffset(geometry.scrollOffset),
          index,
        );
        expect(
          layout.getMaxChildIndexForScrollOffset(geometry.scrollOffset + 102),
          index + 2,
        );
      }
    },
  );

  test('RTL mirrors photo columns without moving date headers', () {
    final layout = TimelineGridLayout(
      counts: [3],
      columns: 3,
      tileExtent: 100,
      headerExtent: 44,
      reverseCrossAxis: true,
    );
    expect(layout.getGeometryForChildIndex(0).crossAxisOffset, 0);
    expect(layout.getGeometryForChildIndex(1).crossAxisOffset, 204);
    expect(layout.getGeometryForChildIndex(3).crossAxisOffset, 0);
  });
}
