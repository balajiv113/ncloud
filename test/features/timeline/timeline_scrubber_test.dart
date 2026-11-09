import 'dart:ui' show SemanticsAction;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/timeline/timeline_scrubber.dart';

void main() {
  testWidgets('hidden scrubber exposes date and screen-reader adjustments', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              ListView.builder(
                controller: controller,
                itemExtent: 100,
                itemCount: 100,
                itemBuilder: (_, _) => const SizedBox(),
              ),
              Positioned(
                right: 0,
                top: 0,
                bottom: 0,
                width: 240,
                child: TimelineScrubber(
                  controller: controller,
                  labelAt: (offset) => 'Day ${offset ~/ 100}',
                  markers: () => [],
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final finder = find.bySemanticsLabel('Scrub timeline by date');
    final node = tester.getSemantics(finder);
    expect(node.getSemanticsData().value, 'Day 0');
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    expect(
      node.getSemanticsData().hasAction(SemanticsAction.decrease),
      isFalse,
    );
    expect(
      tester
          .widget<AnimatedOpacity>(
            find.byKey(const ValueKey('timeline-scrubber-visibility')),
          )
          .opacity,
      0,
    );
    tester.binding.rootPipelineOwner.visitChildren((owner) {
      owner.semanticsOwner!.performAction(node.id, SemanticsAction.increase);
    });
    await tester.pumpAndSettle();
    expect(controller.offset, controller.position.viewportDimension);
    final moved = tester.getSemantics(finder);
    expect(
      moved.getSemanticsData().hasAction(SemanticsAction.decrease),
      isTrue,
    );
    tester.binding.rootPipelineOwner.visitChildren((owner) {
      owner.semanticsOwner!.performAction(moved.id, SemanticsAction.decrease);
    });
    await tester.pumpAndSettle();
    expect(controller.offset, 0);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
