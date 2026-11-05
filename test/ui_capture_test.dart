import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/main.dart';

import 'app_test.dart' show MemoryStore;

void main() {
  testWidgets(
    'capture mobile library preview screens',
    (tester) async {
      final root = Platform.environment['FLUTTER_ROOT'];
      await tester.runAsync(() async {
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
        if (root != null) {
          final font = File(
            '$root/bin/cache/artifacts/material_fonts/Roboto-Regular.ttf',
          );
          if (await font.exists()) {
            await (FontLoader('Roboto')..addFont(
                  font.readAsBytes().then((b) => ByteData.sublistView(b)),
                ))
                .load();
          }
        }
      });
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final oldShadows = debugDisableShadows;
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = oldShadows);
      final key = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: key,
          child: NcloudApp(controller: AppController(store: MemoryStore())),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try demo'));
      await tester.pumpAndSettle();
      for (final (label, name) in [
        ('Timeline', 'timeline'),
        ('Albums', 'albums'),
        ('Drive', 'drive'),
        ('Library', 'library'),
      ]) {
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
        final boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
          await Directory('build/ui').create(recursive: true);
          await File(
            'build/ui/$name.png',
          ).writeAsBytes(bytes!.buffer.asUint8List());
          image.dispose();
        });
        expect(tester.takeException(), isNull);
      }
      debugDisableShadows = oldShadows;
    },
    skip: !const bool.fromEnvironment('CAPTURE_UI'),
  );
}
