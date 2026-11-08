import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/library/domain/browse_target.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/library/library_screen.dart';

import 'support/sample_library.dart';

Future<AppController> _library(
  WidgetTester tester, {
  bool reducedMotion = false,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = const Size(412, 915);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final controller = sampleController();
  addTearDown(controller.dispose);
  unawaited(controller.load());
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reducedMotion),
        child: Directionality(textDirection: direction, child: child!),
      ),
      home: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => LibraryScreen(controller: controller),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return controller;
}

String? _title(WidgetTester tester) =>
    tester.widget<Text>(find.byKey(const ValueKey('library-title'))).data;

Future<void> _swipe(WidgetTester tester, double distance) async {
  await tester.dragFrom(const Offset(205, 30), Offset(distance, 0));
  await tester.pumpAndSettle();
}

SlideTransition _slide(WidgetTester tester) => tester.widget<SlideTransition>(
  find.byKey(const ValueKey('destination-slide')),
);

FadeTransition _fade(WidgetTester tester) => tester.widget<FadeTransition>(
  find.byKey(const ValueKey('destination-fade')),
);

void main() {
  testWidgets('horizontal swipes follow dock order without wrapping', (
    tester,
  ) async {
    final controller = await _library(tester);
    await _swipe(tester, 140);
    expect(controller.destination, Destination.timeline);
    await _swipe(tester, -140);
    expect(controller.destination, Destination.albums);
    expect(_title(tester), 'ncloud');
    await _swipe(tester, -140);
    expect(controller.destination, Destination.drive);
    expect(_title(tester), 'ncloud');
    await _swipe(tester, -140);
    expect(controller.destination, Destination.drive);
    await _swipe(tester, 140);
    expect(controller.destination, Destination.albums);
    await _swipe(tester, 140);
    expect(controller.destination, Destination.timeline);
    expect(_title(tester), 'ncloud');
    expect(tester.takeException(), isNull);
  });

  testWidgets('RTL swipes follow the reading direction', (tester) async {
    final controller = await _library(tester, direction: TextDirection.rtl);
    await _swipe(tester, 140);
    expect(controller.destination, Destination.albums);
    await _swipe(tester, -140);
    expect(controller.destination, Destination.timeline);
  });

  testWidgets('destinations show the app name and nested views keep context', (
    tester,
  ) async {
    final controller = await _library(tester);
    for (final (destination, title) in [
      (Destination.timeline, 'Timeline'),
      (Destination.albums, 'Albums'),
      (Destination.drive, 'Drive'),
      (Destination.favorites, 'Favorites'),
      (Destination.offline, 'Offline'),
    ]) {
      await controller.select(destination);
      await tester.pumpAndSettle();
      expect(_title(tester), 'ncloud', reason: title);
      if (destination == Destination.drive) {
        expect(find.text('Drive'), findsOneWidget);
        expect(find.text('Drive').hitTestable(), findsOneWidget);
      }
    }
    await controller.select(Destination.drive);
    await controller.openFolder(
      controller.items.firstWhere((file) => file.name == 'Photos'),
    );
    await tester.pumpAndSettle();
    expect(_title(tester), 'Photos');
    await controller.openSmartAlbum(['Photos', 'Travel', 'Japan', 'Kyoto']);
    await tester.pumpAndSettle();
    expect(_title(tester), 'Kyoto');
  });

  testWidgets('forward and reverse transitions retain one live scroll tree', (
    tester,
  ) async {
    await _library(tester);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller;
    await tester.tap(find.byKey(const ValueKey('navigate-albums')));
    await tester.pump();
    expect(_slide(tester).position.value.dx, greaterThan(0));
    expect(_fade(tester).opacity.value, lessThan(1));
    await tester.pump(const Duration(milliseconds: 70));
    expect(_slide(tester).position.value.dx, inExclusiveRange(0, .045));
    expect(_fade(tester).opacity.value, inExclusiveRange(.6, 1));
    expect(find.byType(CustomScrollView), findsOneWidget);
    expect(
      tester.widget<CustomScrollView>(find.byType(CustomScrollView)).controller,
      same(scroll),
    );
    await tester.pumpAndSettle();
    expect(_slide(tester).position.value, Offset.zero);
    expect(_fade(tester).opacity.value, 1);
    await tester.tap(find.byKey(const ValueKey('navigate-timeline')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 70));
    expect(_slide(tester).position.value.dx, lessThan(0));
    expect(_fade(tester).opacity.value, lessThan(1));
    await tester.pumpAndSettle();
    expect(_slide(tester).position.value, Offset.zero);
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion switches destinations immediately', (
    tester,
  ) async {
    final controller = await _library(tester, reducedMotion: true);
    for (final destination in [
      Destination.albums,
      Destination.drive,
      Destination.timeline,
    ]) {
      await tester.tap(find.byKey(ValueKey('navigate-${destination.name}')));
      await tester.pump();
      expect(controller.destination, destination);
      expect(_slide(tester).position.value, Offset.zero);
      expect(_fade(tester).opacity.value, 1);
      await tester.pumpAndSettle();
    }
    await _swipe(tester, -140);
    expect(controller.destination, Destination.albums);
    expect(_slide(tester).position.value, Offset.zero);
    expect(_fade(tester).opacity.value, 1);
  });

  testWidgets('rapid destination changes leave no outgoing scroll tree', (
    tester,
  ) async {
    final controller = await _library(tester);
    for (final destination in [
      Destination.albums,
      Destination.drive,
      Destination.timeline,
      Destination.albums,
      Destination.timeline,
    ]) {
      await tester.tap(find.byKey(ValueKey('navigate-${destination.name}')));
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.byType(CustomScrollView), findsOneWidget);
    }
    await tester.pumpAndSettle();
    expect(controller.destination, Destination.timeline);
    expect(_title(tester), 'ncloud');
    expect(_slide(tester).position.value, Offset.zero);
    expect(_fade(tester).opacity.value, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('vertical, short and diagonal drags do not change destination', (
    tester,
  ) async {
    final controller = await _library(tester);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    await tester.dragFrom(const Offset(205, 650), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(controller.destination, Destination.timeline);
    expect(scroll.offset, greaterThan(0));
    final offset = scroll.offset;
    await tester.dragFrom(const Offset(205, 400), const Offset(-45, 0));
    await tester.pumpAndSettle();
    expect(controller.destination, Destination.timeline);
    expect(scroll.offset, closeTo(offset, 1));
    await tester.dragFrom(const Offset(300, 500), const Offset(-130, -110));
    await tester.pumpAndSettle();
    expect(controller.destination, Destination.timeline);
  });

  testWidgets('horizontal album carousels keep their own gestures', (
    tester,
  ) async {
    final controller = await _library(tester);
    await tester.tap(find.byKey(const ValueKey('navigate-albums')));
    await tester.pumpAndSettle();
    final carousel = find
        .byWidgetPredicate(
          (widget) =>
              widget is ListView && widget.scrollDirection == Axis.horizontal,
        )
        .first;
    await tester.drag(carousel, const Offset(-160, 0));
    await tester.pumpAndSettle();
    expect(controller.destination, Destination.albums);
    expect(_title(tester), 'ncloud');
  });

  testWidgets('selection and search cannot be dismissed by a swipe', (
    tester,
  ) async {
    final controller = await _library(tester);
    await tester.longPress(find.bySemanticsLabel('Alpine morning.jpg'));
    await tester.pumpAndSettle();
    expect(_title(tester), '1 selected');
    await _swipe(tester, -140);
    expect(controller.destination, Destination.timeline);
    expect(_title(tester), '1 selected');
    await tester.tap(find.byTooltip('Cancel selection'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search loaded items'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Alpine');
    await _swipe(tester, -140);
    expect(controller.destination, Destination.timeline);
    expect(find.text('Alpine'), findsOneWidget);
  });

  testWidgets('busy operations and multitouch block destination swipes', (
    tester,
  ) async {
    final controller = await _library(tester);
    controller.busy = true;
    await _swipe(tester, -140);
    expect(controller.destination, Destination.timeline);
    controller.busy = false;
    final first = await tester.startGesture(const Offset(205, 30), pointer: 1);
    await first.moveBy(const Offset(-30, 0));
    await tester.pump();
    final second = await tester.startGesture(const Offset(240, 35), pointer: 2);
    await first.moveBy(const Offset(-110, 0));
    await second.up();
    await first.up();
    await tester.pumpAndSettle();
    expect(controller.destination, Destination.timeline);
    expect(_title(tester), 'ncloud');
  });

  testWidgets('nested albums, folders and collections do not swipe away', (
    tester,
  ) async {
    final controller = await _library(tester);
    await tester.tap(find.byKey(const ValueKey('navigate-albums')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('View all Albums')));
    await tester.pumpAndSettle();
    await _swipe(tester, -140);
    expect(controller.destination, Destination.albums);
    expect(_title(tester), 'Albums');
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(_title(tester), 'ncloud');
    await controller.openSmartAlbum(['Photos', 'Travel', 'Japan', 'Kyoto']);
    await tester.pumpAndSettle();
    await _swipe(tester, -140);
    expect(controller.destination, Destination.albums);
    expect(controller.directory, ['Photos', 'Travel', 'Japan', 'Kyoto']);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(_title(tester), 'ncloud');
    await tester.tap(find.byKey(const ValueKey('navigate-drive')));
    await tester.pumpAndSettle();
    await controller.openFolder(
      controller.items.firstWhere((file) => file.name == 'Photos'),
    );
    await tester.pumpAndSettle();
    await _swipe(tester, 140);
    expect(controller.destination, Destination.drive);
    expect(controller.directory, ['Photos']);
    await controller.select(Destination.favorites);
    await tester.pumpAndSettle();
    await _swipe(tester, -140);
    expect(controller.destination, Destination.favorites);
    expect(_title(tester), 'ncloud');
  });

  testWidgets('returning to a destination restores its scroll position', (
    tester,
  ) async {
    await _library(tester);
    final scroll = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    await tester.dragFrom(const Offset(205, 650), const Offset(0, -300));
    await tester.pumpAndSettle();
    final offset = scroll.offset;
    expect(offset, greaterThan(0));
    await tester.tap(find.byKey(const ValueKey('navigate-albums')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('navigate-timeline')));
    await tester.pumpAndSettle();
    expect(scroll.offset, closeTo(offset, 1));
    await tester.tap(find.byKey(const ValueKey('navigate-timeline')));
    await tester.pumpAndSettle();
    expect(
      scroll.offset,
      0,
      reason: 'tapping the active destination resets it',
    );
    expect(tester.takeException(), isNull);
  });
}
