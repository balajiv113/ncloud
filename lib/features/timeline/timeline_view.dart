import 'package:flutter/material.dart';

import '../../app/browse_target.dart';
import '../../app/shell/library_scope.dart';
import '../../app/shell/library_view.dart';
import '../../models.dart';
import '../../shared/ui/drive_list.dart';
import '../../shared/ui/empty_library.dart';
import 'memory_strip.dart';
import 'timeline_grid.dart';
import 'timeline_sections.dart';

/// The Timeline and every view laid out like it, such as Favorites, offline
/// photos and the photos of an album, a person or a map area: dated sections of
/// photos, with memories above the Timeline itself.
class TimelineView extends StatelessWidget {
  const TimelineView({
    super.key,
    required this.scope,
    required this.files,
    required this.tracker,
  });

  final LibraryScope scope;

  /// The files this view shows, already filtered and sorted.
  final List<CloudFile> files;

  /// Records where sections sit, for the scrubber and density changes.
  final TimelineTracker tracker;

  @override
  Widget build(BuildContext context) {
    final c = scope.controller;
    final view = scope.view;
    final media = files.where((f) => f.isMedia).toList();
    final indexed = scope.indexedLayout;
    final showMemories =
        c.destination == Destination.timeline &&
        !view.selecting &&
        view.query.isEmpty &&
        view.filter == MediaFilter.all;
    final Map<String, List<CloudFile>> groups = showMemories
        ? memoryGroups(files)
        : const {};
    final hasGrid = media.isNotEmpty || indexed;
    if (!hasGrid) tracker.clear();
    final localizations = MaterialLocalizations.of(context);
    final others = files.where((f) => !f.isMedia).toList();
    return SliverMainAxisGroup(
      slivers: [
        if (groups.isNotEmpty)
          SliverToBoxAdapter(
            child: MemoryStrip(
              groups: groups,
              controller: c,
              onOpen: scope.open,
            ),
          ),
        if (hasGrid)
          TimelineSlivers(
            controller: c,
            sections: buildTimelineSections(
              media: media,
              indexedDays: indexed ? c.indexedDays : null,
              dayLoaded: c.dayLoaded,
              dayNeedsRefresh: c.dayNeedsRefresh,
              labelFor: (date) => timelineLabel(
                date,
                byMonth: view.density >= 5,
                formatMonth: localizations.formatMonthYear,
                formatDate: localizations.formatMediumDate,
              ),
            ),
            media: media,
            density: view.density,
            tracker: tracker,
            selected: view.selected.keys.toSet(),
            selecting: view.selecting,
            onOpen: scope.open,
            onToggle: scope.toggle,
            onToggleSection: scope.toggleSection,
            wantDays: scope.wantDays,
          ),
        if (c.destination.isCollection && others.isNotEmpty)
          DriveList(
            files: others,
            controller: c,
            selected: view.selected.keys.toSet(),
            selecting: view.selecting,
            onOpen: scope.open,
            onToggle: scope.toggle,
          ),
        if (files.isEmpty && !indexed)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyLibrary(
              failed: c.error != null,
              hasMore: c.hasMore,
              message: scope.emptyMessage,
            ),
          ),
      ],
    );
  }
}
