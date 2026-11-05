import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;

http.Response jsonResponse(Object value) => http.Response(
  jsonEncode(value),
  200,
  headers: {'content-type': 'application/json'},
);

List<Map<String, int>> index() =>
    List.generate(30, (i) => {'dayid': 21000 - i, 'count': 60});

http.Response emptyIncoming() => jsonResponse({
  'ocs': {
    'meta': {'status': 'ok'},
    'data': [],
  },
});

http.Response davForIds(http.Request request) {
  final ids = RegExp(
    r'<d:literal>(\d+)</d:literal>',
  ).allMatches(request.body).map((m) => m[1]!).toList();
  if (ids.length > 100) {
    return http.Response('Search operator limit exceeded', 500);
  }
  return http.Response(
    multistatus(
      ids
          .map(
            (id) =>
                responseEntry(
                  href:
                      '/nextcloud/remote.php/dav/files/alice/Photos/photo-$id.jpg',
                ).replaceAll(
                  '<oc:fileid>42</oc:fileid>',
                  '<oc:fileid>$id</oc:fileid>',
                ),
          )
          .join(),
    ),
    207,
  );
}

MockClient indexedTransport(List<http.Request> calls) =>
    MockClient((request) async {
      calls.add(request);
      if (request.method == 'PROPFIND') {
        return http.Response(multistatus(''), 207);
      }
      if (request.method == 'SEARCH') return davForIds(request);
      if (request.url.path.endsWith('/days')) return jsonResponse(index());
      if (!request.url.path.contains('/days/')) return http.Response('', 404);
      final days = request.url.pathSegments.last.split(',').map(int.parse);
      return jsonResponse([
        for (final day in days)
          for (var i = 0; i < 60; i++)
            {
              'fileid': day * 100 + i,
              'dayid': day,
              'etag': 'revision-$day',
              'epoch': day * 86400 + i,
              'basename': 'photo.jpg',
            },
      ]);
    });

void main() {
  test(
    'indexed discovery stops at a folder with media without listing its subfolders',
    () async {
      final visited = <String>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.method == 'PROPFIND') return http.Response('', 404);
            final folder = request.url.queryParameters['folder'];
            visited.add('${request.url.pathSegments.last}:$folder');
            if (request.url.path.endsWith('/folders/sub')) {
              expect(folder, '/Photos');
              return jsonResponse([
                {
                  'name': 'Trip',
                  'previews': [
                    {'fileid': 42},
                  ],
                },
                {'name': 'Empty', 'previews': []},
              ]);
            }
            if (request.url.queryParameters['limit'] == null) {
              return jsonResponse(index());
            }
            return jsonResponse(
              folder == '/Photos/Trip'
                  ? [
                      {'dayid': 21000, 'count': 4},
                    ]
                  : [],
            );
          }),
        ),
      )..account = account.withPhotoRoot(['Photos']);
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.error, isNull);
      expect(c.smartAlbums.map((a) => a.name), ['Trip']);
      expect(visited.where((path) => path.startsWith('sub:')), ['sub:/Photos']);
      expect(visited, contains('days:/Photos/Trip'));
      expect(c.discoveredFolders, 2);
      expect(c.smartAlbums.single.files.single.id, '42');
    },
  );

  test(
    'WebDAV discovery walks grouping folders and Drive reuses the listings',
    () async {
      final listed = <String>[];
      var searches = 0;
      String directory(String path) =>
          responseEntry(href: '/nextcloud/remote.php/dav/files/alice/$path/')
              .replaceFirst(
                '<d:resourcetype/>',
                '<d:resourcetype><d:collection/></d:resourcetype>',
              )
              .replaceFirst('image/jpeg', 'httpd/unix-directory');
      String photo(String path) =>
          responseEntry(href: '/nextcloud/remote.php/dav/files/alice/$path');
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (request.url.path.endsWith('/shares')) {
                    return emptyIncoming();
                  }
                  if (request.url.path.contains('/dav/photos/')) {
                    return http.Response('', 404);
                  }
                  if (request.method == 'SEARCH') {
                    searches++;
                    expect(request.body, contains('<d:depth>1</d:depth>'));
                    return http.Response(
                      multistatus(photo('Photos/loose.jpg')),
                      207,
                    );
                  }
                  expect(request.method, 'PROPFIND');
                  final path = Uri.decodeFull(
                    request.url.path,
                  ).split('/files/alice/').last.replaceAll(RegExp(r'/$'), '');
                  listed.add(path);
                  return http.Response(
                    multistatus(switch (path) {
                      'Photos' =>
                        photo('Photos/loose.jpg') +
                            directory('Photos/Trip') +
                            directory('Photos/Empty'),
                      'Photos/Trip' => directory('Photos/Trip/Japan'),
                      'Photos/Trip/Japan' =>
                        photo('Photos/Trip/Japan/a.jpg') +
                            directory('Photos/Trip/Japan/Nested'),
                      _ => '',
                    }),
                    207,
                  );
                }),
              ),
            )
            ..account = account.withPhotoRoot(['Photos'])
            ..memoriesAvailable = false;
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.error, isNull);
      expect(c.smartAlbums.map((a) => a.path), [
        ['Photos'],
        ['Photos', 'Trip', 'Japan'],
      ]);
      expect(listed, [
        'Photos',
        'Photos/Empty',
        'Photos/Trip',
        'Photos/Trip/Japan',
      ]);
      expect(searches, 0);
      c.tab = 1;
      await c.goTo(['Photos', 'Trip', 'Japan']);
      expect(c.error, isNull);
      expect(c.items.map((f) => f.name), ['Nested', 'a.jpg']);
      expect(listed, hasLength(4), reason: 'Drive reuses the shared cache');
      await c.openSmartAlbum(['Photos']);
      expect(c.error, isNull);
      expect(c.items.single.name, 'loose.jpg');
      expect(searches, 1);
    },
  );

  test(
    'loose source photos never hide parent albums and open without descendants',
    () async {
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls.add(request);
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.method == 'PROPFIND') return http.Response('', 404);
            if (request.method == 'SEARCH') return davForIds(request);
            if (request.url.path.endsWith('/folders/sub')) {
              return jsonResponse([
                {
                  'name': 'Travel',
                  'previews': [
                    {'fileid': 43},
                  ],
                },
                {
                  'name': 'Family',
                  'previews': [
                    {'fileid': 44},
                  ],
                },
                {'name': 'Empty', 'previews': []},
              ]);
            }
            if (request.url.path.endsWith('/days')) {
              if (request.url.queryParameters['limit'] == null &&
                  request.url.queryParameters['folder'] == '/Photos') {
                expect(
                  request.url.queryParameters.containsKey('recursive'),
                  isFalse,
                );
              }
              return jsonResponse([
                {'dayid': 21000, 'count': 1},
              ]);
            }
            expect(
              request.url.queryParameters.containsKey('recursive'),
              request.url.queryParameters['folder'] != '/Photos',
            );
            return jsonResponse([
              {'fileid': 42, 'dayid': 21000, 'etag': 'cover'},
            ]);
          }),
        ),
      )..account = account.withPhotoRoot(['Photos']);
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.error, isNull);
      expect(c.smartAlbums.map((a) => a.path), [
        ['Photos'],
        ['Photos', 'Travel'],
        ['Photos', 'Family'],
      ]);
      expect(c.discoveredFolders, 3);
      expect(
        calls.where((r) => r.url.path.endsWith('/folders/sub')),
        hasLength(1),
      );
      await c.openSmartAlbum(['Photos']);
      expect(c.error, isNull);
      expect(c.items.map((f) => f.path), [
        ['Photos', 'photo-42.jpg'],
      ]);
      expect(c.albumIncludesSubfolders, isFalse);
      await c.openSmartAlbum(['Photos', 'Travel']);
      expect(c.error, isNull);
      expect(c.albumIncludesSubfolders, isTrue);
      expect(
        calls
            .lastWhere((r) => r.url.path.endsWith('/days'))
            .url
            .queryParameters['recursive'],
        '1',
      );
    },
  );

  test(
    'startup warms Smart and native albums from disk without waiting for network discovery',
    () async {
      final root = await Directory.systemTemp.createTemp('ncloud-hot-albums-');
      addTearDown(() => root.delete(recursive: true));
      final cache = LocalCache(() async => root);
      await cache.writeDocument(
        'incoming-albums-v1|${account.server}|${account.userId}',
        {'updated': DateTime.now().toIso8601String(), 'albums': []},
      );
      await cache.writeDocument(
        'album-source|${account.server}|${account.userId}',
        {
          'path': ['Photos'],
        },
      );
      await cache.writeDocument(
        'album-catalogue-v5|${account.server}|${account.userId}|Photos',
        {
          'updated': DateTime.now().toIso8601String(),
          'albums': [
            {
              'path': ['Photos', 'Travel'],
              'covers': [
                const CloudFile(
                  path: ['Photos', 'Travel', 'cover-42'],
                  name: 'Travel',
                  isDirectory: false,
                  contentType: 'image/jpeg',
                  id: '42',
                ).toJson(),
              ],
            },
          ],
          'native': [
            {
              'name': 'Best days',
              'path': ['albums', 'best'],
              'count': 12,
              'coverId': '43',
              'shared': false,
            },
          ],
        },
      );
      final timeline = Completer<http.Response>();
      var calls = 0;
      final store = MemoryStore()..value = account.encode();
      final c = AppController(
        store: store,
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls++;
            if (request.url.path.endsWith('/clusters/recognize')) {
              return jsonResponse([]);
            }
            expect(request.url.path, endsWith('/days'));
            return timeline.future;
          }),
        ),
      );
      addTearDown(c.dispose);
      final initializing = c.initialize();
      for (var i = 0; i < 100 && c.smartAlbums.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.tab, 0);
      expect(c.smartAlbums.single.name, 'Travel');
      expect(c.nativeAlbums.single.name, 'Best days');
      expect(c.nativeAlbums.single.count, 12);
      expect(c.photoRoot, ['Photos']);
      expect(c.catalogueError, isNull);
      await c.selectTab(4);
      expect(c.loading, isFalse);
      expect(c.smartAlbums.single.name, 'Travel');
      expect(
        calls,
        2,
        reason: 'Timeline and People each fetch one small index',
      );
      timeline.complete(jsonResponse([]));
      await initializing;
      expect(c.tab, 4);
      expect(c.smartAlbums.single.name, 'Travel');
    },
  );

  test(
    'refresh retains the full catalogue and tab switches join background discovery',
    () async {
      final folders = Completer<http.Response>();
      var refresh = false;
      var folderCalls = 0;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.method == 'PROPFIND') return http.Response('', 404);
            if (request.url.path.endsWith('/folders/sub')) {
              if (request.url.queryParameters['folder'] != '/Photos') {
                return jsonResponse([]);
              }
              folderCalls++;
              if (refresh) return folders.future;
              return jsonResponse([
                {
                  'name': 'Travel',
                  'previews': [
                    {'fileid': 42},
                  ],
                },
                {
                  'name': 'Family',
                  'previews': [
                    {'fileid': 43},
                  ],
                },
              ]);
            }
            if (request.url.queryParameters['limit'] == '1' &&
                request.url.queryParameters['folder'] != '/Photos') {
              return jsonResponse([
                {'dayid': 21000, 'count': 1},
              ]);
            }
            return jsonResponse([]);
          }),
        ),
      )..account = account.withPhotoRoot(['Photos']);
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.smartAlbums, hasLength(2));
      final lengths = <int>[];
      c.addListener(() => lengths.add(c.smartAlbums.length));
      refresh = true;
      final refreshing = c.load();
      await Future<void>.delayed(Duration.zero);
      expect(c.discoveringAlbums, isTrue);
      expect(c.smartAlbums, hasLength(2));
      final revisiting = c.selectTab(4);
      await Future<void>.delayed(Duration.zero);
      expect(folderCalls, 2, reason: 'revisiting joins the in-flight refresh');
      folders.complete(
        jsonResponse([
          {
            'name': 'Travel',
            'previews': [
              {'fileid': 42},
            ],
          },
          {
            'name': 'Family',
            'previews': [
              {'fileid': 43},
            ],
          },
          {
            'name': 'Events',
            'previews': [
              {'fileid': 44},
            ],
          },
        ]),
      );
      await Future.wait([refreshing, revisiting]);
      expect(c.smartAlbums, hasLength(3));
      expect(lengths.every((n) => n >= 2), isTrue);
      expect(c.discoveringAlbums, isFalse);
      expect(c.catalogueError, isNull);
    },
  );

  test(
    'refreshing the current photo listing never publishes an empty loading frame',
    () async {
      var refresh = false;
      final pending = Completer<http.Response>();
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (refresh) return pending.future;
                  return http.Response(multistatus(responseEntry()), 207);
                }),
              ),
            )
            ..account = account
            ..memoriesAvailable = false;
      addTearDown(c.dispose);
      await c.load();
      expect(c.items, hasLength(1));
      final lengths = <int>[];
      c.addListener(() => lengths.add(c.items.length));
      refresh = true;
      final loading = c.load();
      await Future<void>.delayed(Duration.zero);
      expect(c.loading, isTrue);
      expect(c.refreshing, isTrue);
      expect(c.items, hasLength(1));
      pending.complete(http.Response(multistatus(responseEntry()), 207));
      await loading;
      expect(lengths.every((n) => n == 1), isTrue);
      expect(c.error, isNull);
    },
  );

  test(
    'an empty index stops without fetching details or falling back to an entire drive scan',
    () async {
      var calls = 0;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls++;
            expect(request.url.path, endsWith('/days'));
            return jsonResponse([]);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(calls, 1);
      expect(c.memoriesAvailable, isTrue);
      expect(c.items, isEmpty);
      expect(c.hasMore, isFalse);
      expect(c.error, isNull);
    },
  );

  test(
    'scoped favorites use identical index/detail filters and preserve the camera calendar day',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          if (request.method == 'SEARCH') return davForIds(request);
          expect(
            request.url.queryParameters['folder'],
            '/Photos/Trip & family',
          );
          expect(request.url.queryParameters['recursive'], '1');
          expect(request.url.queryParameters['fav'], '1');
          expect(request.url.queryParameters['nopreload'], '1');
          return jsonResponse(
            request.url.path.endsWith('/days')
                ? [
                    {'dayid': 21000, 'count': 1},
                  ]
                : [
                    {
                      'fileid': 42,
                      'dayid': 21000,
                      'epoch': 21000 * 86400 - 3600,
                      'etag': 'new',
                    },
                  ],
          );
        }),
      );
      addTearDown(client.close);
      final days = await client.memoryDays(
        account,
        path: ['Photos', 'Trip & family'],
        favorites: true,
      );
      final photos = await client.memoryDayFiles(
        account,
        [days!.single.id],
        path: ['Photos', 'Trip & family'],
        favorites: true,
      );
      final file = CloudFile.fromJson(
        photos.single.toJson(),
      ).atPath(['Photos', 'moved.jpg']);
      final calendar = DateTime.fromMillisecondsSinceEpoch(
        21000 * 86400000,
        isUtc: true,
      );
      expect(
        file.timelineDate,
        DateTime(calendar.year, calendar.month, calendar.day),
      );
      expect(
        file.taken,
        DateTime.fromMillisecondsSinceEpoch(
          (21000 * 86400 - 3600) * 1000,
          isUtc: true,
        ),
      );
      expect(file.etag, 'new');
    },
  );

  test(
    'scroll batches resolve real paths below the Nextcloud search operator limit',
    () async {
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls.add(request);
            expect(request.headers['Authorization'], account.authorization);
            expect(request.url.path, startsWith('/nextcloud/'));
            if (request.method == 'PROPFIND') {
              return http.Response(multistatus(''), 207);
            }
            if (request.method == 'SEARCH') return davForIds(request);
            expect(request.url.queryParameters['nopreload'], '1');
            expect(request.url.queryParameters['folder'], '/');
            if (request.url.path.endsWith('/days')) {
              return jsonResponse(index());
            }
            final days = request.url.pathSegments.last
                .split(',')
                .map(int.parse);
            return jsonResponse([
              for (final day in days)
                for (var i = 0; i < 60; i++)
                  {
                    'fileid': day * 100 + i,
                    'dayid': day,
                    'etag': 'revision-$day',
                    'epoch': day * 86400 + i,
                    'basename': 'photo.jpg',
                  },
            ]);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(c.memoriesAvailable, isTrue);
      expect(c.indexedDays, hasLength(30));
      expect(c.items, hasLength(180));
      expect(calls, hasLength(4));
      expect(c.items.first.path.first, 'Photos');
      expect(c.items.first.taken, isNotNull);
      expect(c.items.first.modified, DateTime.utc(2026, 11, 4, 10, 11, 12));
      expect(c.items.first.etag, startsWith('revision-'));
      await c.loadNextPage();
      expect(c.items, hasLength(360));
      expect(calls, hasLength(7));
      expect(c.hasMore, isTrue);
      expect(c.error, isNull);
      await c.selectTab(1);
      final before = calls.length;
      await c.selectTab(0);
      expect(c.items, hasLength(360));
      expect(calls.length, before);
      final copy = CloudFile.fromJson(
        c.items.first.toJson(),
      ).withFavorite(false);
      expect(copy.captureDay, c.items.first.captureDay);
      expect(copy.taken, c.items.first.taken);
      final calendar = DateTime.fromMillisecondsSinceEpoch(
        copy.captureDay! * 86400000,
        isUtc: true,
      );
      expect(
        copy.timelineDate,
        DateTime(calendar.year, calendar.month, calendar.day),
      );
    },
  );

  test(
    'simultaneous scroll events coalesce and cancelled results do not advance the cached cursor',
    () async {
      final pending = Completer<http.Response>();
      final started = Completer<void>();
      var details = 0;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.method == 'PROPFIND') {
              return http.Response(multistatus(''), 207);
            }
            if (request.method == 'SEARCH') return davForIds(request);
            if (request.url.path.endsWith('/days')) {
              return jsonResponse(index());
            }
            details++;
            if (details == 2) {
              started.complete();
              return pending.future;
            }
            final day = int.parse(
              request.url.pathSegments.last.split(',').first,
            );
            return jsonResponse([
              {'fileid': day, 'dayid': day},
            ]);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      final first = c.items.single.key;
      final next = c.loadNextPage();
      await started.future;
      await c.loadNextPage();
      expect(details, 2);
      await c.selectTab(1);
      pending.complete(
        jsonResponse([
          {'fileid': 200, 'dayid': 20997},
        ]),
      );
      await next;
      await c.selectTab(0);
      expect(c.items.single.key, first);
      await c.loadNextPage();
      expect(details, 3);
      expect(c.items, hasLength(2));
    },
  );

  test(
    'revisiting Albums joins an in-progress discovery instead of restarting the folder walk',
    () async {
      final started = Completer<void>();
      final pending = Completer<http.Response>();
      var walks = 0;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.method == 'PROPFIND') {
              return http.Response(multistatus(''), 207);
            }
            if (request.url.path.endsWith('/folders/sub')) {
              walks++;
              started.complete();
              return pending.future;
            }
            return jsonResponse([]);
          }),
        ),
      )..account = account.withPhotoRoot(['Photos']);
      addTearDown(c.dispose);
      final first = c.selectTab(4);
      await started.future;
      await c.selectTab(1);
      final revisited = c.selectTab(4);
      pending.complete(jsonResponse([]));
      await Future.wait([first, revisited]);
      expect(walks, 1);
      expect(c.loading, isFalse);
      expect(c.discoveringAlbums, isFalse);
      expect(c.error, isNull);
    },
  );

  test(
    'album catalogue walks grouping folders to the first media and hides empty branches',
    () async {
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls.add(request);
            if (request.url.path.endsWith('/shares')) return emptyIncoming();
            if (request.method == 'PROPFIND') return http.Response('', 404);
            if (request.url.path.endsWith('/clusters/recognize')) {
              return jsonResponse([]);
            }
            expect(request.method, 'GET');
            final folder = request.url.queryParameters['folder'];
            if (request.url.path.endsWith('/folders/sub')) {
              return jsonResponse(switch (folder) {
                '/Photos' => [
                  {
                    'name': 'Travel',
                    'previews': [
                      {'fileid': 42},
                    ],
                  },
                  {'name': 'Empty', 'previews': []},
                ],
                '/Photos/Travel' => [
                  {
                    'name': 'Japan',
                    'previews': [
                      {'fileid': 43},
                    ],
                  },
                  {
                    'name': 'Italy',
                    'previews': [
                      {'fileid': 44},
                    ],
                  },
                ],
                _ => fail('media folders are not walked: $folder'),
              });
            }
            expect(request.url.path, endsWith('/days'));
            final query = request.url.queryParameters;
            if (query['limit'] == null) return jsonResponse(index());
            expect(query.containsKey('recursive'), isFalse);
            return jsonResponse(
              folder == '/Photos/Travel/Japan' ||
                      folder == '/Photos/Travel/Italy'
                  ? [
                      {'dayid': 21000, 'count': 3},
                    ]
                  : [],
            );
          }),
        ),
      )..account = account.withPhotoRoot(['Photos']);
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.error, isNull);
      expect(c.smartAlbums.map((a) => a.name), ['Japan', 'Italy']);
      expect(c.smartAlbums.first.files.single.id, '43');
      expect(c.discoveredFolders, 4);
      expect(
        calls.any((r) => RegExp(r'/days/\d').hasMatch(r.url.path)),
        isFalse,
      );
      expect(calls.where((r) => r.method == 'SEARCH'), isEmpty);
      expect(
        calls
            .where((r) => r.url.path.endsWith('/folders/sub'))
            .map((r) => r.url.queryParameters['folder']),
        ['/Photos', '/Photos/Travel'],
      );
      final count = calls.length;
      await c.selectTab(4);
      expect(calls.length, count);
      expect(c.discoveringAlbums, isFalse);
    },
  );

  test(
    'cached page and cursor resume after restart without re-downloading loaded photos',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ncloud-memory-index-',
      );
      addTearDown(() => root.delete(recursive: true));
      final cache = LocalCache(() async => root);
      var calls = 0;
      AppController create() => AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls++;
            if (request.method == 'SEARCH') return davForIds(request);
            if (request.url.path.endsWith('/days')) {
              return jsonResponse(index());
            }
            final day = int.parse(
              request.url.pathSegments.last.split(',').first,
            );
            return jsonResponse([
              {'fileid': day, 'dayid': day},
            ]);
          }),
        ),
      )..account = account;
      final first = create();
      await first.load();
      await Future<void>.delayed(const Duration(milliseconds: 60));
      first.dispose();
      final restored = create();
      addTearDown(restored.dispose);
      await restored.selectTab(0);
      expect(calls, 3);
      expect(restored.items, hasLength(1));
      await restored.loadNextPage();
      expect(calls, 5);
      expect(restored.items, hasLength(2));
    },
  );

  test(
    'missing Memories falls back once, but authorization, server and malformed responses remain errors',
    () async {
      for (final status in [404, 401, 403, 500, 200]) {
        var search = 0;
        final c = AppController(
          store: MemoryStore(),
          client: NextcloudClient(
            transport: MockClient((request) async {
              if (request.method == 'SEARCH') {
                search++;
                return http.Response(multistatus(responseEntry()), 207);
              }
              return http.Response(
                status == 200 ? '{"wrong":"shape"}' : '',
                status,
              );
            }),
          ),
        )..account = account;
        addTearDown(c.dispose);
        await c.load();
        expect(search, status == 404 ? 1 : 0);
        expect(c.error, status == 404 ? isNull : isNotNull);
      }
    },
  );

  test(
    'a large day is complete, never silently truncated by the Memories 100-item limit',
    () async {
      final requests = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            requests.add(request);
            if (request.method == 'SEARCH') return davForIds(request);
            if (request.url.path.endsWith('/days')) {
              return jsonResponse([
                {'dayid': 21000, 'count': 450},
                {'dayid': 20999, 'count': 50},
              ]);
            }
            expect(request.url.queryParameters.containsKey('limit'), isFalse);
            return jsonResponse(
              List.generate(450, (i) => {'fileid': i + 1, 'dayid': 21000}),
            );
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(c.items, hasLength(450));
      expect(requests.where((r) => r.method == 'SEARCH'), hasLength(5));
      expect(requests.any((r) => r.url.path.endsWith('/days/20999')), isFalse);
      expect(c.hasMore, isTrue);
    },
  );

  testWidgets(
    'scrolling prefetches near the end, not the full collection on opening',
    (tester) async {
      var searches = 0;
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (request.method != 'SEARCH') return http.Response('', 404);
                  searches++;
                  final offset = (searches - 1) * 200;
                  return http.Response(
                    multistatus(
                      List.generate(
                        200,
                        (i) =>
                            responseEntry(
                              href:
                                  '/nextcloud/remote.php/dav/files/alice/Photos/p-${offset + i}.jpg',
                            ).replaceAll(
                              '<oc:fileid>42</oc:fileid>',
                              '<oc:fileid>${offset + i}</oc:fileid>',
                            ),
                      ).join(),
                    ),
                    207,
                  );
                }),
              ),
            )
            ..account = account
            ..memoriesAvailable = false;
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pumpAndSettle();
      expect(searches, 1);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -120));
      await tester.pumpAndSettle();
      expect(searches, 1);
      final scroll = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      scroll.position.jumpTo(scroll.position.maxScrollExtent - 300);
      await tester.pumpAndSettle();
      expect(searches, 2);
      expect(c.items, hasLength(400));
      expect(find.textContaining('Load more'), findsNothing);
    },
  );

  testWidgets(
    'Shared shows incoming folder albums, excludes outgoing/files/empty folders, and opens scoped media',
    (tester) async {
      var searches = 0;
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (request.url.path.endsWith('/shares')) {
                    return jsonResponse({
                      'ocs': {
                        'meta': {'status': 'ok'},
                        'data': [
                          {
                            'path': '/Shared/Trip',
                            'item_type': 'folder',
                            'uid_owner': 'bob',
                            'uid_file_owner': 'bob',
                            'share_type': 0,
                          },
                          {
                            'path': '/Shared/Trip',
                            'item_type': 'folder',
                            'uid_owner': 'bob',
                            'share_type': 1,
                          },
                          {
                            'path': '/Shared/Empty',
                            'item_type': 'folder',
                            'uid_owner': 'bob',
                            'share_type': 0,
                          },
                          {
                            'path': '/Photos/Outgoing',
                            'item_type': 'folder',
                            'uid_owner': 'alice',
                            'share_type': 0,
                          },
                          {
                            'path': '/Shared/single.jpg',
                            'item_type': 'file',
                            'uid_owner': 'bob',
                            'share_type': 0,
                          },
                        ],
                      },
                    });
                  }
                  if (request.method == 'PROPFIND' &&
                      request.url.path.endsWith('/Photos')) {
                    return http.Response(multistatus(''), 207);
                  }
                  if (request.method != 'SEARCH') return http.Response('', 404);
                  searches++;
                  if (request.body.contains('/Shared/Empty')) {
                    return http.Response(multistatus(''), 207);
                  }
                  expect(request.body, contains('/files/alice/Shared/Trip'));
                  return http.Response(
                    multistatus(
                      responseEntry(
                        href:
                            '/nextcloud/remote.php/dav/files/alice/Shared/Trip/Nested/target.jpg',
                      ),
                    ),
                    207,
                  );
                }),
              ),
            )
            ..account = account.withPhotoRoot(['Photos'])
            ..tab = 5
            ..memoriesAvailable = false;
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pumpAndSettle();
      expect(searches, 2);
      expect(c.items, isEmpty);
      expect(c.hasMore, isFalse);
      expect(c.sharedAlbums.map((a) => a.name), ['Trip']);
      expect(find.byType(SliverGrid), findsOneWidget);
      expect(find.text('Trip'), findsOneWidget);
      expect(find.text('Outgoing'), findsNothing);
      await tester.tap(find.text('Trip'));
      await tester.pumpAndSettle();
      expect(searches, 3);
      expect(c.items.single.path.last, 'target.jpg');
      expect(c.directory, ['Shared', 'Trip']);
      expect(c.hasMore, isFalse);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(c.sharedAlbumHome, isTrue);
      expect(find.text('Trip'), findsOneWidget);
      expect(searches, 3, reason: 'Shared album catalogue is hot cached');
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(c.tab, 4);
      expect(find.text('Shared'), findsNothing);
      expect(find.text('Shared with you'), findsOneWidget);
      expect(find.text('Trip'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('View all Shared with you')),
      );
      await tester.tap(find.byKey(const ValueKey('View all Shared with you')));
      await tester.pumpAndSettle();
      expect(c.sharedAlbumHome, isTrue);
      expect(searches, 3);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'timeline loads requested indexed days on demand in one batch',
    () async {
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(transport: indexedTransport(calls)),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(c.indexedDays, hasLength(30));
      final last = c.indexedDays.last.id;
      expect(c.dayLoaded(c.indexedDays.first.id), isTrue);
      expect(c.dayLoaded(last), isFalse);
      c.ensureDays([last - 0, last + 1]);
      c.ensureDays([last]);
      while (c.fetchingDays) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(c.dayLoaded(last), isTrue);
      expect(c.dayLoaded(last + 1), isTrue);
      expect(c.items, hasLength(300));
      final dayRequests = calls
          .where((r) => RegExp(r'/days/\d').hasMatch(r.url.path))
          .map((r) => r.url.pathSegments.last)
          .toList();
      expect(dayRequests.last.split(',').toSet(), {'$last', '${last + 1}'});
      final before = calls.length;
      c.ensureDays([last]);
      expect(c.fetchingDays, isFalse);
      expect(calls.length, before);
    },
  );

  testWidgets('timeline scrubber drags through the full indexed library', (
    tester,
  ) async {
    final calls = <http.Request>[];
    final c = AppController(
      store: MemoryStore(),
      client: NextcloudClient(transport: indexedTransport(calls)),
    )..account = account;
    await tester.pumpWidget(NcloudApp(controller: c));
    await tester.pumpAndSettle();
    expect(c.indexedDays, hasLength(30));
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final max = scroll.position.maxScrollExtent;
    expect(max, greaterThan(scroll.position.viewportDimension * 10));
    scroll.position.jumpTo(40);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final thumb = find.byKey(const ValueKey('timeline-scrubber'));
    expect(thumb, findsOneWidget);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Scrub timeline by date'), findsOneWidget);
    semantics.dispose();
    await tester.drag(thumb, const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, greaterThan(max * .9));
    expect(c.dayLoaded(c.indexedDays.last.id), isTrue);
    expect(c.error, isNull);
    await tester.pump(const Duration(seconds: 2));
  });
}
