import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/timeline/media_grid_tile.dart';
import 'package:ncloud/features/viewer/asset_viewer.dart';
import 'package:ncloud/models.dart';

import '../../support/sample_library.dart';

class _LiveLibrary extends SampleLibrary {
  int clips = 0;

  @override
  Future<Uint8List> livePhotoVideo(Account account, CloudFile file) async {
    clips++;
    return Uint8List.fromList([0, 0, 0, 20, ...'ftypqt  '.codeUnits, 1, 2]);
  }
}

const livePhoto = CloudFile(
  path: ['Photos', 'live.heic'],
  name: 'live.heic',
  isDirectory: false,
  contentType: 'image/heic',
  id: '9',
  etag: 'e',
  liveId: 'apple-id',
);

const stillPhoto = CloudFile(
  path: ['Photos', 'still.jpg'],
  name: 'still.jpg',
  isDirectory: false,
  contentType: 'image/jpeg',
  id: '10',
);

void main() {
  testWidgets('grid tiles mark Live Photos and only those', (tester) async {
    final controller = sampleController();
    addTearDown(controller.dispose);
    Widget tile(CloudFile file) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 120,
          height: 120,
          child: MediaGridTile(
            file: file,
            controller: controller,
            selected: false,
            selecting: false,
            onTap: () {},
            onLongPress: null,
          ),
        ),
      ),
    );
    await tester.pumpWidget(tile(livePhoto));
    expect(find.byIcon(Icons.motion_photos_on_outlined), findsOneWidget);
    await tester.pumpWidget(tile(stillPhoto));
    expect(find.byIcon(Icons.motion_photos_on_outlined), findsNothing);
  });

  testWidgets(
    'the viewer offers LIVE only on Live Photos and fetches the clip',
    (tester) async {
      final library = _LiveLibrary();
      final controller = sampleController(library);
      addTearDown(controller.dispose);

      await tester.pumpWidget(
        MaterialApp(
          home: AssetViewer(
            key: const ValueKey('plain'),
            files: const [stillPhoto],
            initialIndex: 0,
            controller: controller,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('LIVE'), findsNothing);

      await tester.pumpWidget(
        MaterialApp(
          home: AssetViewer(
            key: const ValueKey('live'),
            files: const [livePhoto],
            initialIndex: 0,
            controller: controller,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('LIVE'), findsOneWidget);

      await tester.runAsync(() async {
        await tester.tap(find.text('LIVE'));
        for (var i = 0; i < 40 && library.clips == 0; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
      });
      expect(library.clips, 1);
      await tester.pump(const Duration(milliseconds: 100));
    },
  );
}
