import 'package:flutter/rendering.dart';

/// One full-width date header followed by square photo tiles per section.
/// Stores offsets per date, not per photo, even for very large libraries.
class TimelineGridLayout extends SliverGridLayout {
  TimelineGridLayout({
    required List<int> counts,
    required this.columns,
    required this.tileExtent,
    required this.headerExtent,
    this.reverseCrossAxis = false,
  }) {
    var index = 0;
    var offset = 0.0;
    for (final count in counts) {
      starts.add(index);
      offsets.add(offset);
      index += count + 1;
      offset += headerExtent + ((count + columns - 1) ~/ columns) * stride;
    }
    itemCount = index;
    scrollExtent = offset;
  }

  final int columns;
  final double tileExtent;
  final double headerExtent;
  final bool reverseCrossAxis;
  final List<int> starts = [];
  final List<double> offsets = [];
  late final int itemCount;
  late final double scrollExtent;
  double get stride => tileExtent + 2;

  int _section(num value, List<num> boundaries) {
    var low = 0;
    var high = boundaries.length;
    while (low < high) {
      final mid = (low + high) ~/ 2;
      if (boundaries[mid] <= value) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return (low - 1).clamp(0, boundaries.length - 1);
  }

  int sectionForIndex(int index) => _section(index, starts);

  @override
  int getMinChildIndexForScrollOffset(double scrollOffset) {
    if (starts.isEmpty) return 0;
    final section = _section(scrollOffset, offsets);
    final local = scrollOffset - offsets[section] - headerExtent;
    if (local < 0) return starts[section];
    final row = local ~/ stride;
    return (starts[section] + 1 + row * columns).clamp(0, itemCount - 1);
  }

  @override
  int getMaxChildIndexForScrollOffset(double scrollOffset) {
    if (starts.isEmpty) return 0;
    // The trailing edge is exclusive.
    final first = getMinChildIndexForScrollOffset(
      scrollOffset > 0 ? scrollOffset - 0.000001 : 0,
    );
    final section = sectionForIndex(first);
    if (first == starts[section]) return first;
    final end = section + 1 < starts.length
        ? starts[section + 1] - 1
        : itemCount - 1;
    return (first + columns - 1).clamp(first, end);
  }

  @override
  SliverGridGeometry getGeometryForChildIndex(int index) {
    final section = sectionForIndex(index);
    final local = index - starts[section] - 1;
    if (local < 0) {
      return SliverGridGeometry(
        scrollOffset: offsets[section],
        crossAxisOffset: 0,
        mainAxisExtent: headerExtent,
        crossAxisExtent: columns * tileExtent + (columns - 1) * 2,
      );
    }
    final column = local % columns;
    return SliverGridGeometry(
      scrollOffset:
          offsets[section] + headerExtent + (local ~/ columns) * stride,
      crossAxisOffset:
          (reverseCrossAxis ? columns - column - 1 : column) * stride,
      mainAxisExtent: stride,
      crossAxisExtent: tileExtent,
    );
  }

  @override
  double computeMaxScrollOffset(int childCount) => scrollExtent;
}

class TimelineGridDelegate extends SliverGridDelegate {
  const TimelineGridDelegate(this.layout);
  final TimelineGridLayout layout;

  @override
  SliverGridLayout getLayout(SliverConstraints constraints) => layout;

  @override
  bool shouldRelayout(TimelineGridDelegate oldDelegate) =>
      layout != oldDelegate.layout;
}
