import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/core/storage/local_cache.dart';

import 'app_test.dart' show MemoryStore;
import 'memories_test.dart' show jsonResponse;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;
import 'timeline_speed_test.dart' show settle;

void main() {
  test(
    'cached complete days reload from SQLite instead of the server',
    () async {
      final root = await Directory.systemTemp.createTemp('ncloud-day-db');
      final cache = LocalCache(() async => Directory('${root.path}/cache'));
      var details = 0;
      final c = AppController(
        store: MemoryStore(),
        cache: cache,
        pathlessTimeline: true,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.method == 'PROPFIND') {
              return http.Response(multistatus(''), 207);
            }
            if (request.url.path.endsWith('/days')) {
              return jsonResponse([
                {'dayid': 21000, 'count': 2},
              ]);
            }
            details++;
            return jsonResponse([
              for (final id in [1, 2])
                {'fileid': id, 'dayid': 21000, 'etag': 'one'},
            ]);
          }),
        ),
      )..account = account;
      addTearDown(() async {
        c.dispose();
        await cache.close();
        await root.delete(recursive: true);
      });
      await c.load();
      await cache.close(); // Drain queued persistence, then reopen lazily.
      final key = c.items.first.key;
      c.fileStore.removeKeys([key]); // RAM pressure is not a server deletion.
      await c.loadNextPage();
      // Publishing prunes the evicted day before it can be requested again.
      // A fresh tab load also hydrates persisted memberships outside RAM.
      await c.load(refresh: false);
      expect(c.items, hasLength(2));
      expect(details, 1);
      await c.load(refresh: true);
      expect(
        details,
        2,
        reason: 'manual refresh must not reuse stale DB details',
      );
    },
  );

  test(
    'Drive updates quietly after an etag change and remains idle otherwise',
    () async {
      var revision = 'one';
      var name = 'before.jpg';
      var listings = 0;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.headers['Depth'] == '0') {
              return http.Response(
                multistatus(
                  responseEntry(
                    properties: '<d:getetag>"$revision"</d:getetag>',
                  ),
                ),
                207,
              );
            }
            listings++;
            return http.Response(
              multistatus(
                responseEntry(
                  name: name,
                  href: '/nextcloud/remote.php/dav/files/alice/$name',
                  properties: '<d:getetag>"$revision"</d:getetag>',
                ),
              ),
              207,
            );
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.selectTab(1);
      expect(c.items.single.name, 'before.jpg');
      await c.checkForChanges();
      final before = listings;
      await c.checkForChanges();
      expect(listings, before);
      revision = 'two';
      name = 'after.jpg';
      var sawEmpty = false;
      c.addListener(() {
        if (c.items.isEmpty) sawEmpty = true;
      });
      expect(await c.checkForChanges(), isTrue);
      expect(c.items.single.name, 'after.jpg');
      expect(sawEmpty, isFalse);
      expect(listings, before + 1);
    },
  );

  test('known push IDs refresh only their cached day', () async {
    final c = AppController(
      store: MemoryStore(),
      pathlessTimeline: true,
      client: NextcloudClient(
        transport: MockClient((request) async {
          if (request.method == 'PROPFIND') {
            return http.Response(
              multistatus(
                responseEntry(properties: '<d:getetag>"unchanged"</d:getetag>'),
              ),
              207,
            );
          }
          if (request.url.path.endsWith('/days')) {
            return jsonResponse([
              {'dayid': 21000, 'count': 1},
              {'dayid': 20999, 'count': 1},
            ]);
          }
          return jsonResponse([
            for (final day
                in request.url.pathSegments.last.split(',').map(int.parse))
              {'fileid': day, 'dayid': day, 'etag': 'one'},
          ]);
        }),
      ),
    )..account = account;
    addTearDown(c.dispose);
    await c.load();
    await c.checkForChanges();
    c.busy = true;
    expect(
      await c.checkForChanges(changedFileIds: {'21000'}, force: true),
      isFalse,
    );
    c.busy = false;
    expect(
      await c.checkForChanges(),
      isTrue,
      reason: 'a push arriving during a transfer must not be discarded',
    );
    expect(c.dayNeedsRefresh(21000), isTrue);
    expect(c.dayNeedsRefresh(20999), isFalse);
  });

  test(
    'etag checks skip unchanged indexes and hot-update equal-count edits',
    () async {
      var revision = 'one';
      var firstId = 1;
      var indexCalls = 0;
      var detailCalls = 0;
      final requests = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        pathlessTimeline: true,
        client: NextcloudClient(
          transport: MockClient((request) async {
            requests.add(request);
            if (request.method == 'PROPFIND') {
              return http.Response(
                multistatus(
                  request.headers['Depth'] == '0'
                      ? responseEntry(
                          properties: '<d:getetag>"$revision"</d:getetag>',
                        )
                      : '',
                ),
                207,
              );
            }
            if (request.url.path.endsWith('/days')) {
              indexCalls++;
              return jsonResponse([
                {'dayid': 21000, 'count': 2},
              ]);
            }
            detailCalls++;
            return jsonResponse([
              for (final id in [firstId, 2])
                {'fileid': id, 'dayid': 21000, 'etag': revision},
            ]);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(c.items, hasLength(2));
      await c.checkForChanges();
      final before = indexCalls;
      for (var i = 0; i < 3; i++) {
        expect(await c.checkForChanges(), isFalse);
      }
      expect(indexCalls, before);
      expect(requests.last.headers['Depth'], '0');
      final oldDetails = detailCalls;
      revision = 'two';
      firstId = 3; // A deletion plus addition leaves the day count unchanged.
      expect(await c.checkForChanges(), isTrue);
      expect(c.dayLoaded(21000), isTrue);
      expect(c.dayNeedsRefresh(21000), isTrue);
      expect(
        c.items.any((f) => f.id == '1'),
        isTrue,
        reason: 'cached pixels stay visible while the changed day refreshes',
      );
      c.ensureDays([21000]);
      await settle(() => !c.fetchingDays);
      expect(c.items.map((f) => f.id).toSet(), {'2', '3'});
      expect(c.items.every((f) => f.etag == 'two'), isTrue);
      expect(detailCalls, oldDetails + 1);
      expect(c.dayNeedsRefresh(21000), isFalse);
      expect(c.fileStore.where((f) => f.id == '1'), isEmpty);
      final requestCount = requests.length;
      c.setBrowsingActive(false);
      await c.checkForChanges(force: true);
      expect(requests.length, requestCount);
    },
  );

  test('failed checks preserve cached data and expose an error', () async {
    var fail = false;
    final c = AppController(
      store: MemoryStore(),
      pathlessTimeline: true,
      client: NextcloudClient(
        transport: MockClient((request) async {
          if (request.method == 'PROPFIND') {
            if (fail) return http.Response('', 503);
            return http.Response(multistatus(''), 207);
          }
          return jsonResponse(
            request.url.path.endsWith('/days')
                ? [
                    {'dayid': 21000, 'count': 1},
                  ]
                : [
                    {'fileid': 1, 'dayid': 21000, 'etag': 'one'},
                  ],
          );
        }),
      ),
    )..account = account;
    addTearDown(c.dispose);
    await c.load();
    fail = true;
    await expectLater(c.checkForChanges(), throwsA(isA<CloudException>()));
    expect(c.items.single.id, '1');
    expect(c.notice, contains('Could not check'));
    expect(c.timelineChanged, isFalse);
  });
}
