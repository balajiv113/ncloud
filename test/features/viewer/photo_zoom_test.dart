import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/viewer/asset_viewer.dart';
import 'package:ncloud/features/viewer/video_asset.dart';
import 'package:ncloud/features/viewer/zoom_asset.dart';

import '../../support/sample_library.dart';

void main() {
  test('playback time shows hours only when needed', () {
    expect(formatPlaybackTime(const Duration(seconds: 5)), '00:05');
    expect(
      formatPlaybackTime(const Duration(minutes: 12, seconds: 3)),
      '12:03',
    );
    expect(
      formatPlaybackTime(const Duration(hours: 1, minutes: 2, seconds: 3)),
      '1:02:03',
    );
  });

  testWidgets(
    'double-tap zooms a photo in and back, and locks paging while zoomed',
    (tester) async {
      await pumpSampleLibrary(tester);
      await tester.tap(find.bySemanticsLabel('Alpine morning.jpg'));
      await tester.pumpAndSettle();
      expect(find.byType(AssetViewer), findsOneWidget);

      PageView pages() => tester.widget<PageView>(find.byType(PageView));
      final photo = find.byType(ZoomAsset);
      expect(pages().physics, isNull);

      Future<void> doubleTap() async {
        final at = tester.getCenter(photo);
        await tester.tapAt(at);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(at);
        await tester.pumpAndSettle();
      }

      await doubleTap();
      final zoomed = tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!
          .value
          .getMaxScaleOnAxis();
      expect(zoomed, closeTo(ZoomAsset.doubleTapScale, 0.01));
      expect(pages().physics, isA<NeverScrollableScrollPhysics>());

      await doubleTap();
      expect(
        tester
            .widget<InteractiveViewer>(find.byType(InteractiveViewer))
            .transformationController!
            .value
            .getMaxScaleOnAxis(),
        closeTo(1, 0.01),
      );
      expect(pages().physics, isNull);
    },
  );
}
