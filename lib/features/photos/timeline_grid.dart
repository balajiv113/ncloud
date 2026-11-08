import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';
import 'media_grid_tile.dart';
import 'timeline_layout.dart';
import 'timeline_sections.dart';

/// The Timeline's photo grid: a header for each dated section followed by its
/// photos, laid out lazily so only the tiles near the viewport are built.
///
/// While it lays out it records where each section and row sits in [tracker],
/// and it asks [wantDays] for indexed days whose photos have not loaded yet.
class TimelineSlivers extends StatelessWidget {
  const TimelineSlivers({
    super.key,
    required this.controller,
    required this.sections,
    required this.media,
    required this.density,
    required this.tracker,
    required this.selected,
    required this.selecting,
    required this.onOpen,
    required this.onToggle,
    required this.onToggleSection,
    required this.wantDays,
  });

  final AppController controller;
  final List<TimelineSection> sections;

  /// Every photo of the view, which the viewer pages through.
  final List<CloudFile> media;

  /// Photos per row on a phone; wider screens add two columns.
  final int density;
  final TimelineTracker tracker;
  final Set<String> selected;
  final bool selecting;
  final void Function(CloudFile file, List<CloudFile> visible) onOpen;
  final void Function(CloudFile file) onToggle;

  /// Selects, or when [all] are already selected clears, a section's files.
  final void Function(List<CloudFile> files, bool all) onToggleSection;
  final void Function(Iterable<int> days) wantDays;

  @override
  Widget build(BuildContext context) {
    Widget tile(CloudFile file) => MediaGridTile(
      file: file,
      controller: controller,
      selected: selected.contains(file.key),
      selecting: selecting,
      onTap: () => onOpen(file, media),
      onLongPress: file.readOnly ? null : () => onToggle(file),
    );
    double? layoutWidth;
    late TimelineGridLayout layout;
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        tracker.start = constraints.precedingScrollExtent;
        final columns = constraints.crossAxisExtent > 650
            ? density + 2
            : density;
        final tileExtent =
            (constraints.crossAxisExtent - (columns - 1) * 2) / columns;
        final headerExtent =
            44.0 + MediaQuery.textScalerOf(context).scale(13) - 13;
        if (layoutWidth != constraints.crossAxisExtent) {
          layoutWidth = constraints.crossAxisExtent;
          layout = TimelineGridLayout(
            counts: [for (final section in sections) section.expected],
            columns: columns,
            tileExtent: tileExtent,
            headerExtent: headerExtent,
            reverseCrossAxis: Directionality.of(context) == TextDirection.rtl,
          );
          tracker.clear();
          for (final (index, section) in sections.indexed) {
            tracker.stops.add((
              offset: layout.offsets[index],
              label: section.label,
              date: section.date,
            ));
            for (
              var start = 0;
              start < section.files.length;
              start += columns
            ) {
              final end = (start + columns).clamp(0, section.files.length);
              tracker.rows.add((
                offset:
                    layout.offsets[index] +
                    headerExtent +
                    (start ~/ columns) * (tileExtent + 2),
                files: section.files.sublist(start, end),
              ));
            }
          }
        }
        final placeholder = Theme.of(
          context,
        ).colorScheme.surfaceContainerHighest;
        return SliverGrid(
          gridDelegate: TimelineGridDelegate(layout),
          delegate: SliverChildBuilderDelegate((context, index) {
            final sectionIndex = layout.sectionForIndex(index);
            final section = sections[sectionIndex];
            final photoIndex = index - layout.starts[sectionIndex] - 1;
            // Request a few sections ahead first so the visible section,
            // requested last, is fetched first.
            for (var next = sectionIndex + 3; next >= sectionIndex; next--) {
              if (next < sections.length && sections[next].pending.isNotEmpty) {
                wantDays(sections[next].pending);
              }
            }
            if (photoIndex < 0) {
              final all = section.files.every((f) => selected.contains(f.key));
              return Padding(
                padding: const EdgeInsets.only(left: 16, right: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        section.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Select ${section.label}',
                      iconSize: 18,
                      onPressed: section.files.every((f) => f.readOnly)
                          ? null
                          : () => onToggleSection(section.files, all),
                      icon: Icon(
                        all ? Icons.check_circle : Icons.radio_button_unchecked,
                      ),
                    ),
                  ],
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: photoIndex < section.files.length
                  ? tile(section.files[photoIndex])
                  : ColoredBox(color: placeholder),
            );
          }, childCount: layout.itemCount),
        );
      },
    );
  }
}
