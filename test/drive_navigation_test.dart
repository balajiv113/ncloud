import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/storage/file_store.dart';
import 'package:ncloud/library_screen.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/media_listing.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;

void main() {
  for (final folderSnapshot in [true, false]) {
    test(
      'Drive rejects an out-of-scope ${folderSnapshot ? 'folder snapshot with matching etag' : 'hydrated browse listing'}',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'ncloud-drive-cache-',
        );
        final cache = LocalCache(() async => root);
        final store = FileStore()
          ..putFolder(
            ['Trips'],
            [
              const CloudFile(
                path: ['Other', 'Summer'],
                name: 'Summer',
                isDirectory: true,
                id: '42',
              ),
            ],
            etag: '"unchanged"',
          );
        if (folderSnapshot) {
          await cache.writeLibrary(
            'library-v1|${account.server}|${account.userId}',
            store,
          );
        } else {
          final key =
              'browse-v4|${account.server}|${account.userId}|1|false|Trips|';
          final files = store.where((_) => true);
          await cache.writeListing(key, files);
          final listing = MediaListing()..add(FileStore(), files);
          await cache.writeDocument(key, listing.toJson());
        }
        var walks = 0;
        final controller =
            AppController(
                store: MemoryStore(),
                cache: cache,
                client: NextcloudClient(
                  transport: MockClient((request) async {
                    if (request.headers['Depth'] == '1') walks++;
                    return http.Response(
                      multistatus(
                        responseEntry(
                              href:
                                  '/nextcloud/remote.php/dav/files/alice/Trips/',
                              properties: '<d:getetag>"unchanged"</d:getetag>',
                            ) +
                            (request.headers['Depth'] == '1'
                                ? responseEntry(
                                    href:
                                        '/nextcloud/remote.php/dav/files/alice/Trips/Summer/',
                                  ).replaceFirst(
                                    '<d:resourcetype/>',
                                    '<d:resourcetype><d:collection/></d:resourcetype>',
                                  )
                                : ''),
                      ),
                      207,
                    );
                  }),
                ),
              )
              ..account = account
              ..tab = 1
              ..directory = ['Trips'];
        try {
          await controller.load(refresh: false);
          expect(controller.error, isNull);
          expect(walks, 1);
          expect(controller.items.map((file) => file.path), [
            ['Trips', 'Summer'],
          ]);
        } finally {
          controller.dispose();
          await cache.close();
          await root.delete(recursive: true);
        }
      },
    );
  }

  testWidgets(
    'Drive opens two nested folders and their contents including cached revisits',
    (tester) async {
      final requests = <String>[];
      const root = '/nextcloud/remote.php/dav/files/alice';
      String folder(String path) => responseEntry(href: '$root/$path/')
          .replaceFirst(
            '<d:resourcetype/>',
            '<d:resourcetype><d:collection/></d:resourcetype>',
          )
          .replaceFirst('image/jpeg', 'httpd/unix-directory')
          .replaceFirst(
            '<oc:fileid>42</oc:fileid>',
            '<oc:fileid>$path</oc:fileid>',
          );
      final client = NextcloudClient(
        transport: MockClient((request) async {
          if (request.method != 'PROPFIND') return http.Response('', 404);
          if (request.headers['Depth'] == '1') requests.add(request.url.path);
          final nested = request.url.path.endsWith('/Trips');
          final summer = request.url.path.endsWith('/Trips/Summer');
          return http.Response(
            multistatus(
              summer
                  ? folder('Trips/Summer') +
                        folder('Trips/Summer/Empty') +
                        responseEntry(
                          href: '$root/Trips/Summer/notes.txt',
                        ).replaceFirst('image/jpeg', 'text/plain')
                  : nested
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
      for (var attempt = 0; attempt < 2; attempt++) {
        await controller.goTo([]);
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
        expect(
          find.byKey(const ValueKey('drive:Trips/Summer')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('drive:Other')), findsNothing);
        expect(find.text('Summer'), findsOneWidget);
        expect(controller.items.map((f) => f.path), [
          ['Trips', 'Summer'],
        ]);
        await tester.tap(find.byKey(const ValueKey('drive:Trips/Summer')));
        await tester.pumpAndSettle();
        expect(controller.directory, ['Trips', 'Summer']);
        expect(controller.error, isNull);
        expect(controller.items.map((f) => f.path), [
          ['Trips', 'Summer', 'Empty'],
          ['Trips', 'Summer', 'notes.txt'],
        ]);
        expect(find.byKey(const ValueKey('drive:Trips/Summer')), findsNothing);
        expect(
          find.byKey(const ValueKey('drive:Trips/Summer/Empty')),
          findsOneWidget,
        );
        expect(find.text('notes.txt'), findsOneWidget);
        expect(requests, [root, '$root/Trips', '$root/Trips/Summer']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.iOS,
    }),
  );
}
