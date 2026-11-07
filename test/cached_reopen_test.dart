import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/file_store.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'memories_test.dart' show emptyIncoming, jsonResponse;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;

void main() {
  late Directory root;
  late LocalCache cache;
  final session = account.withPhotoRoot(['Photos']);
  final owner = '${account.server}|${account.userId}';
  final catalogueKey = 'album-catalogue-v5|$owner|Photos';
  final browseKey = 'browse-v4|$owner|4|true|Photos/Trip|';
  final file = CloudFile(
    path: const ['Photos', 'Trip', 'one.jpg'],
    name: 'one.jpg',
    isDirectory: false,
    contentType: 'image/jpeg',
    id: '7',
    captureDay: 21000,
    taken: DateTime.fromMillisecondsSinceEpoch(21000 * 86400000),
    etag: 'old-photo',
  );
  final old = DateTime.now()
      .subtract(const Duration(days: 3))
      .toIso8601String();

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ncloud-cached-reopen');
    cache = LocalCache(() async => Directory('${root.path}/cache'));
  });
  tearDown(() async {
    await cache.close();
    await root.delete(recursive: true);
  });

  Future<void> seedCatalogue() => cache.writeDocument(catalogueKey, {
    'updated': old,
    'etag': '"folder-one"',
    'albums': [
      SmartAlbum(path: const ['Photos', 'Trip'], files: [file]).toJson(),
    ],
    'native': <Object>[],
  });

  http.Response folderVersion(String version) => http.Response(
    multistatus(responseEntry(properties: '<d:getetag>"$version"</d:getetag>')),
    207,
  );

  test(
    'expired Smart catalogue stays visible and skips discovery when etag matches',
    () async {
      await seedCatalogue();
      final gate = Completer<void>();
      var etagRequests = 0;
      final discovery = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.url.path.contains('/dav/photos/')) {
              return http.Response('', 404);
            }
            if (request.url.path.endsWith('/clusters/recognize')) {
              return jsonResponse([]);
            }
            if (request.method == 'PROPFIND') {
              expect(request.headers['Depth'], '0');
              etagRequests++;
              await gate.future;
              return folderVersion('folder-one');
            }
            discovery.add(request);
            return http.Response('', 500);
          }),
        ),
      )..account = session;
      addTearDown(c.dispose);
      final opening = c.selectTab(4);
      for (var i = 0; i < 100 && etagRequests == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(etagRequests, 1);
      expect(
        c.smartAlbums.single.path,
        ['Photos', 'Trip'],
        reason: 'cached cards must appear before the etag response',
      );
      gate.complete();
      await opening;
      expect(c.catalogueError, isNull);
      expect(
        discovery,
        isEmpty,
        reason: 'no folder walk or day query for unchanged catalogue',
      );
      expect((await cache.readDocument(catalogueKey))!['etag'], '"folder-one"');
    },
  );

  test(
    'changed catalogue etag rebuilds Smart albums instead of trusting old cards',
    () async {
      await seedCatalogue();
      var walks = 0;
      final c = AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.url.path.contains('/dav/photos/')) {
              return http.Response('', 404);
            }
            if (request.url.path.endsWith('/clusters/recognize')) {
              return jsonResponse([]);
            }
            if (request.method == 'PROPFIND') {
              return folderVersion('folder-two');
            }
            if (request.url.path.endsWith('/folders/sub')) {
              walks++;
              return jsonResponse([
                {
                  'name': 'New album',
                  'previews': [
                    {'fileid': 8},
                  ],
                },
              ]);
            }
            if (request.url.path.endsWith('/days')) {
              return jsonResponse(
                request.url.queryParameters['limit'] == '1' &&
                        request.url.queryParameters['folder'] == '/Photos'
                    ? <Object>[]
                    : [
                        {'dayid': 21000, 'count': 1},
                      ],
              );
            }
            return http.Response('', 500);
          }),
        ),
      )..account = session;
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.catalogueError, isNull);
      expect(walks, 1);
      expect(c.smartAlbums.single.name, 'New album');
      expect((await cache.readDocument(catalogueKey))!['etag'], '"folder-two"');
    },
  );

  test(
    'changed album etag refreshes same-count metadata and keeps old photos visible',
    () async {
      await cache.writeLibrary(
        'library-v1|$owner',
        FileStore()..putAll([file]),
      );
      await cache.writeDocument(browseKey, {
        'keys': [file.key],
        'days': [
          {'id': 21000, 'count': 1},
        ],
        'loaded': [21000],
        'staleDays': <int>[],
        'offset': 0,
        'more': false,
        'updated': old,
        'scopeEtag': '"folder-one"',
      });
      var details = 0;
      final gate = Completer<void>();
      final c = AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.method == 'PROPFIND') {
              return folderVersion('folder-two');
            }
            if (request.method == 'SEARCH') {
              return http.Response(
                multistatus(
                  responseEntry(
                    href:
                        '/nextcloud/remote.php/dav/files/alice/Photos/Trip/one.jpg',
                  ).replaceFirst(
                    '<oc:fileid>42</oc:fileid>',
                    '<oc:fileid>7</oc:fileid>',
                  ),
                ),
                207,
              );
            }
            if (request.url.path.endsWith('/days')) {
              return jsonResponse([
                {'dayid': 21000, 'count': 1},
              ]);
            }
            details++;
            await gate.future;
            return jsonResponse([
              {'fileid': 7, 'dayid': 21000, 'etag': 'new-photo'},
            ]);
          }),
        ),
      )..account = session;
      addTearDown(c.dispose);
      final opening = c.openSmartAlbum(['Photos', 'Trip']);
      for (var i = 0; i < 100 && details == 0; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(
        details,
        1,
        reason: 'matching day counts cannot prove a photo was not edited',
      );
      expect(c.items.single.etag, 'old-photo');
      gate.complete();
      await opening;
      expect(c.error, isNull);
      expect(c.items.single.etag, 'new-photo');
      expect(
        (await cache.readDocument(browseKey))!['scopeEtag'],
        '"folder-two"',
      );
    },
  );

  test(
    'cached album membership survives invalidation and reuses an unchanged folder',
    () async {
      await cache.writeLibrary(
        'library-v1|$owner',
        FileStore()..putAll([file]),
      );
      await cache.writeDocument(browseKey, {
        'keys': [file.key],
        'days': [
          {'id': 21000, 'count': 1},
        ],
        'loaded': [21000],
        'staleDays': <int>[],
        'offset': 0,
        'more': false,
        'updated': old,
        'scopeEtag': '"folder-one"',
      });
      await cache.invalidateListings('library-v1|$owner');
      var details = 0;
      final gate = Completer<void>();
      var requested = false;
      final c = AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.method == 'PROPFIND') {
              requested = true;
              await gate.future;
              return folderVersion('folder-one');
            }
            details++;
            return http.Response('', 500);
          }),
        ),
      )..account = session;
      addTearDown(c.dispose);
      final opening = c.openSmartAlbum(['Photos', 'Trip']);
      for (var i = 0; i < 100 && !requested; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(requested, isTrue);
      expect(c.items.single.id, '7');
      gate.complete();
      await opening;
      expect(c.error, isNull);
      expect(c.items.single.etag, 'old-photo');
      expect(details, 0);
      expect(c.dayNeedsRefresh(21000), isFalse);
    },
  );
}
