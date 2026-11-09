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
class TimelineView extends StatefulWidget {
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
  State<TimelineView> createState() => _TimelineViewState();
}

/// What the view derives from its files. Grouping thousands of photos by day
/// is far costlier than laying a frame out, and the shell rebuilds on every
/// controller notification, so this is kept until its inputs change.
class _Derived {
  _Derived(this.media, this.others, this.groups, this.sections);

  final List<CloudFile> media;
  final List<CloudFile> others;
  final Map<String, List<CloudFile>> groups;
  final List<TimelineSection> sections;
}

class _TimelineViewState extends State<TimelineView> {
  _Derived _derive(BuildContext context) {
    final scope = widget.scope;
    final c = scope.controller;
    final view = scope.view;
    final files = widget.files;
    final indexed = scope.indexedLayout;
    final localizations = MaterialLocalizations.of(context);
    final showMemories =
        c.destination == Destination.timeline &&
        !view.selecting &&
        view.query.isEmpty &&
        view.filter == MediaFilter.all;
    final key = (
      files,
      indexed,
      indexed ? c.indexedDays : null,
      c.dayLoadState,
      showMemories,
      view.density,
      localizations,
    );
    final memo = view.timelineMemo;
    if (memo.key == key) return memo.value! as _Derived;
    final media = files.where((f) => f.isMedia).toList();
    final derived = _Derived(
      media,
      files.where((f) => !f.isMedia).toList(),
      showMemories ? memoryGroups(files) : const {},
      media.isEmpty && !indexed
          ? const []
          : buildTimelineSections(
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
    );
    memo
      ..key = key
      ..value = derived;
    return derived;
  }

  @override
  Widget build(BuildContext context) {
    final scope = widget.scope;
    final c = scope.controller;
    final view = scope.view;
    final files = widget.files;
    final derived = _derive(context);
    final indexed = scope.indexedLayout;
    final hasGrid = derived.media.isNotEmpty || indexed;
    if (!hasGrid) widget.tracker.clear();
    return SliverMainAxisGroup(
      slivers: [
        if (derived.groups.isNotEmpty)
          SliverToBoxAdapter(
            child: MemoryStrip(
              groups: derived.groups,
              controller: c,
              onOpen: scope.open,
            ),
          ),
        if (hasGrid)
          TimelineSlivers(
            controller: c,
            sections: derived.sections,
            media: derived.media,
            density: view.density,
            tracker: widget.tracker,
            selected: view.selected.keys.toSet(),
            selecting: view.selecting,
            onOpen: scope.open,
            onToggle: scope.toggle,
            onToggleSection: scope.toggleSection,
            wantDays: scope.wantDays,
          ),
        if (c.destination.isCollection && derived.others.isNotEmpty)
          DriveList(
            files: derived.others,
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
