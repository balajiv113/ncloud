import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/library_screen.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;

void main() {
  testWidgets(
    'iOS Drive displays unique direct children and opens the correct folder',
    (tester) async {
      final requests = <String>[];
      const root = '/nextcloud/remote.php/dav/files/alice';
      String folder(String path) => responseEntry(href: '$root/$path/')
          .replaceFirst(
            '<d:resourcetype/>',
            '<d:resourcetype><d:collection/></d:resourcetype>',
          )
          .replaceFirst('image/jpeg', 'httpd/unix-directory');
      final client = NextcloudClient(
        transport: MockClient((request) async {
          if (request.method != 'PROPFIND') return http.Response('', 404);
          if (request.headers['Depth'] == '1') requests.add(request.url.path);
          final nested = request.url.path.endsWith('/Trips');
          return http.Response(
            multistatus(
              nested
                  ? folder('Unrelated') +
                        folder('Trips') +
                        folder('Trips/Summer') +
                        folder('Trips/Summer') +
                        folder('Trips/Summer/Summer') +
                        folder('Other/Summer')
                  : folder('Trips') +
                        folder('Trips') +
                        folder('Other') +
                        folder('Trips/Summer'),
            ),
            207,
          );
        }),
      );
      final controller = AppController(store: MemoryStore(), client: client)
        ..account = account
        ..tab = 1;
      addTearDown(controller.dispose);
      await controller.load();
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: controller,
            builder: (_, _) => LibraryScreen(controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('drive:Trips')), findsOneWidget);
      expect(find.byKey(const ValueKey('drive:Other')), findsOneWidget);
      expect(find.text('Summer'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('drive:Trips')));
      await tester.pumpAndSettle();
      expect(controller.directory, ['Trips']);
      expect(find.byKey(const ValueKey('drive:Trips/Summer')), findsOneWidget);
      expect(find.byKey(const ValueKey('drive:Other')), findsNothing);
      expect(find.text('Summer'), findsOneWidget);
      expect(controller.items.map((f) => f.path), [
        ['Trips', 'Summer'],
      ]);
      expect(requests, [root, '$root/Trips']);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
