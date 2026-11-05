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

http.Response davForIds(http.Request request) {
  final ids = RegExp(
    r'<d:literal>(\d+)</d:literal>',
  ).allMatches(request.body).map((m) => m[1]!).toList();
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

void main() {
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
    'indexed days disable preloading; one scroll batch resolves real paths in one DAV request',
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
      expect(calls, hasLength(3));
      expect(c.items.first.path.first, 'Photos');
      expect(c.items.first.taken, isNotNull);
      expect(c.items.first.modified, DateTime.utc(2026, 11, 4, 10, 11, 12));
      expect(c.items.first.etag, startsWith('revision-'));
      await c.loadNextPage();
      expect(c.items, hasLength(360));
      expect(calls, hasLength(5));
      expect(c.hasMore, isTrue);
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
            if (details == 2) return pending.future;
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
    'album catalogue walks indexed folders, hides grouping/empty folders, and fetches no photo collections',
    () async {
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls.add(request);
            if (request.method == 'PROPFIND') return http.Response('', 404);
            expect(request.method, 'GET');
            if (request.url.path.endsWith('/folders/sub')) {
              final folder = request.url.queryParameters['folder'];
              return jsonResponse(switch (folder) {
                '/Photos' => [
                  {
                    'name': 'Travel',
                    'fileid': 1,
                    'previews': [
                      {'fileid': 42},
                    ],
                  },
                  {'name': 'Empty', 'fileid': 2, 'previews': []},
                ],
                '/Photos/Travel' => [
                  {
                    'name': 'Kyoto',
                    'fileid': 3,
                    'previews': [
                      {'fileid': 42},
                    ],
                  },
                ],
                _ => [],
              });
            }
            expect(request.url.path, endsWith('/days'));
            final query = request.url.queryParameters;
            if (query['limit'] == null) return jsonResponse(index());
            expect(query.containsKey('recursive'), isFalse);
            return jsonResponse(
              query['folder'] == '/Photos/Travel/Kyoto'
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
      expect(c.smartAlbums.map((a) => a.name), ['Kyoto']);
      expect(c.discoveredFolders, 3);
      expect(
        calls.any((r) => RegExp(r'/days/\d').hasMatch(r.url.path)),
        isFalse,
      );
      expect(calls.where((r) => r.method == 'SEARCH'), isEmpty);
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
      expect(requests.where((r) => r.method == 'SEARCH'), hasLength(3));
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
    'sparse shared results remain reachable by scrolling after bounded viewport prefetch',
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
                          {'path': '/Photos/target.jpg'},
                        ],
                      },
                    });
                  }
                  if (request.method != 'SEARCH') return http.Response('', 404);
                  searches++;
                  final count = searches < 4 ? 200 : 1;
                  return http.Response(
                    multistatus(
                      List.generate(
                        count,
                        (i) => responseEntry(
                          href:
                              '/nextcloud/remote.php/dav/files/alice/Photos/${searches < 4 ? 'other-$searches-$i' : 'target'}.jpg',
                        ),
                      ).join(),
                    ),
                    207,
                  );
                }),
              ),
            )
            ..account = account
            ..tab = 5
            ..memoriesAvailable = false;
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pumpAndSettle();
      expect(searches, 3);
      expect(c.items, isEmpty);
      expect(c.hasMore, isTrue);
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
      await tester.pumpAndSettle();
      expect(searches, 4);
      expect(c.items.single.path.last, 'target.jpg');
      expect(c.hasMore, isFalse);
    },
  );
}
