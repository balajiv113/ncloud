import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../app/browse_target.dart';
import 'timeline_scrubber.dart';
import 'timeline_sections.dart';

/// Floating controls over a scrolling photo view: the date scrubber on the
/// right edge and, on the Timeline, the pill announcing new photos.
List<Widget> timelineOverlays(
  BuildContext context, {
  required AppController controller,
  required ScrollController scroll,
  required TimelineTracker tracker,
  required bool selecting,
  required VoidCallback showChanges,
}) => [
  Positioned(
    right: 0,
    top: 64,
    bottom: 112,
    width: 240,
    child: TimelineScrubber(
      controller: scroll,
      labelAt: (offset) => tracker.labelAt(
        offset,
        MaterialLocalizations.of(context).formatMonthYear,
      ),
      markers: tracker.yearMarkers,
    ),
  ),
  if (controller.destination == Destination.timeline &&
      controller.timelineChanged &&
      !selecting)
    Positioned(
      top: MediaQuery.paddingOf(context).top + 72,
      left: 0,
      right: 0,
      child: Center(
        child: FilledButton.icon(
          onPressed: showChanges,
          style: FilledButton.styleFrom(
            shape: const StadiumBorder(),
            elevation: 4,
          ),
          icon: const Icon(Icons.arrow_upward, size: 18),
          label: Text(switch (controller.newPhotos) {
            0 => 'Timeline updated',
            1 => '1 new photo',
            final n => '$n new photos',
          }),
        ),
      ),
    ),
];
