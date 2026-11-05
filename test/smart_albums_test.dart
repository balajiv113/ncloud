import 'dart:async';
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

String page(int offset, int count) => multistatus(
  List.generate(
    count,
    (i) => responseEntry(
      href:
          '/nextcloud/remote.php/dav/files/alice/Photos/photo-${offset + i}.jpg',
    ),
  ).join(),
);

void main() {
  test(
    'every page is fetched automatically for timeline, favorites and Smart albums',
    () async {
      for (final tab in [0, 2, 4]) {
        final offsets = <int>[];
        final c = AppController(
          store: MemoryStore(),
          client: NextcloudClient(
            transport: MockClient((request) async {
              if (request.method == 'PROPFIND') return http.Response('', 404);
              final offset = int.parse(
                RegExp(
                  r'<sd:firstresult>(\d+)</sd:firstresult>',
                ).firstMatch(request.body)!.group(1)!,
              );
              offsets.add(offset);
              return http.Response(page(offset, offset < 400 ? 200 : 1), 207);
            }),
          ),
        )..account = account;
        addTearDown(c.dispose);
        var sawFirstPage = false;
        c.addListener(() {
          if (c.items.length == 200 && c.loadingMore && !c.loading)
            sawFirstPage = true;
        });
        await c.selectTab(tab);
        expect(offsets, [0, 200, 400], reason: 'tab $tab');
        expect(c.items, hasLength(401));
        expect(sawFirstPage, isTrue);
        expect(c.hasMore, isFalse);
        expect(c.loadingMore, isFalse);
        if (tab == 4) expect(c.smartAlbums.single.files, hasLength(401));
      }
    },
  );

  test(
    'a stale background page cannot replace a newly opened Drive folder',
    () async {
      final pending = Completer<http.Response>();
      var startedSecondPage = false;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.method == 'PROPFIND')
              return http.Response(multistatus(''), 207);
            final second = request.body.contains(
              '<sd:firstresult>200</sd:firstresult>',
            );
            if (second) {
              startedSecondPage = true;
              return pending.future;
            }
            return http.Response(page(0, 200), 207);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      final timeline = c.load();
      while (!startedSecondPage) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.selectTab(1);
      pending.complete(http.Response(page(200, 1), 207));
      await timeline;
      expect(c.tab, 1);
      expect(c.items, isEmpty);
      expect(c.error, isNull);
      expect(c.loadingMore, isFalse);
    },
  );

  test('repeated server pages stop with an explicit error', () async {
    var calls = 0;
    final c = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((request) async {
          calls++;
          return http.Response(page(0, 200), 207);
        }),
      ),
    )..account = account;
    addTearDown(c.dispose);
    await c.load();
    expect(calls, 2);
    expect(c.items, hasLength(200));
    expect(c.error, contains('repeated a page'));
    expect(c.loadingMore, isFalse);
  });

  test(
    'full cached library remains visible during refresh; deleted items leave only on completion',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ncloud-full-listing-',
      );
      addTearDown(() => root.delete(recursive: true));
      final cache = LocalCache(() async => root);
      var refresh = false;
      final c = AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((request) async {
            final offset = int.parse(
              RegExp(
                r'<sd:firstresult>(\d+)</sd:firstresult>',
              ).firstMatch(request.body)!.group(1)!,
            );
            return http.Response(
              page(
                offset,
                offset == 0
                    ? 200
                    : refresh
                    ? 1
                    : 2,
              ),
              207,
            );
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      refresh = true;
      var retainedOlderItem = false;
      c.addListener(() {
        if (c.loadingMore && c.items.length == 202) retainedOlderItem = true;
      });
      await c.load();
      expect(retainedOlderItem, isTrue);
      expect(c.items, hasLength(201));
      expect(c.libraryFiles, hasLength(201));
    },
  );

  test(
    'native albums preserve empty albums, names, member IDs and DAV URLs',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.method, 'PROPFIND');
          expect(request.headers['Depth'], '1');
          if (request.url.path.endsWith('/albums')) {
            return http.Response(
              '''<d:multistatus xmlns:d="DAV:" xmlns:nc="http://nextcloud.org/ns">
          <d:response><d:href>/nextcloud/remote.php/dav/photos/alice/albums/Trip%20%26%20friends</d:href>
          <d:propstat><d:prop><nc:original-name>Trip &amp; friends</nc:original-name><nc:nbItems>2</nc:nbItems>
          <nc:last-photo>42</nc:last-photo></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
          <d:response><d:href>/nextcloud/remote.php/dav/photos/alice/albums/Empty</d:href>
          <d:propstat><d:prop><nc:nbItems>0</nc:nbItems></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        </d:multistatus>''',
              207,
            );
          }
          return http.Response(
            '''<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
        <d:response><d:href>/nextcloud/remote.php/dav/photos/alice/albums/Trip%20%26%20friends/42</d:href>
        <d:propstat><d:prop><d:getcontenttype>image/jpeg</d:getcontenttype><oc:fileid>42</oc:fileid></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
        <d:response><d:href>/nextcloud/remote.php/dav/photos/alice/albums/Trip%20%26%20friends/99</d:href>
        <d:propstat><d:prop><d:displayname>Shared.jpg</d:displayname><d:getcontenttype>image/jpeg</d:getcontenttype>
        <oc:fileid>99</oc:fileid></d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response>
      </d:multistatus>''',
            207,
          );
        }),
      );
      addTearDown(client.close);
      final albums = await client.albums(account);
      expect(albums.map((a) => a.name), ['Trip & friends', 'Empty']);
      expect(albums.last.count, 0);
      final photo = CloudFile(
        path: ['Photos', 'Original.jpg'],
        name: 'Original.jpg',
        isDirectory: false,
        id: '42',
        contentType: 'image/jpeg',
      );
      final files = await client.albumFiles(account, albums.first, [photo]);
      expect(files.first, same(photo));
      expect(files.last.name, 'Shared.jpg');
      expect(files.last.readOnly, isTrue);
      expect(
        client.fileUri(account, files.last).path,
        '/nextcloud/remote.php/dav/photos/alice/albums/Trip%20%26%20friends/99',
      );
    },
  );

  test(
    'missing native albums are optional but permission and server errors are surfaced',
    () async {
      var code = 404;
      final client = NextcloudClient(
        transport: MockClient((_) async => http.Response('', code)),
      );
      addTearDown(client.close);
      expect(await client.albums(account), isEmpty);
      code = 403;
      await expectLater(client.albums(account), throwsA(isA<CloudException>()));
      code = 503;
      await expectLater(client.albums(account), throwsA(isA<CloudException>()));
    },
  );

  testWidgets(
    'group filters bypass folders and native albums remain separate',
    (tester) async {
      final c = AppController(store: MemoryStore());
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Albums'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Library'), findsNothing);
      expect(find.text('Kyoto'), findsOneWidget);
      expect(find.text('Empty folder'), findsNothing);
      expect(find.text('Best days'), findsNothing);
      await tester.tap(find.text('Nextcloud albums'));
      await tester.pumpAndSettle();
      expect(find.text('Best days'), findsOneWidget);
      expect(find.text('Kyoto'), findsNothing);
      await tester.tap(find.text('Best days'));
      await tester.pumpAndSettle();
      expect(c.items, hasLength(3));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ChoiceChip, 'Travel'));
      await tester.pumpAndSettle();
      expect(find.text('Coast & country'), findsNothing);
      await tester.tap(find.text('View all photos'));
      await tester.pumpAndSettle();
      expect(c.directory, ['Photos', 'Travel']);
      expect(c.items, hasLength(8));
      expect(find.bySemanticsLabel('Alpine morning.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
