import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/features/library/domain/browse_target.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/features/library/domain/album_members.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';

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
    'album reconciliation distinguishes missing metadata from zero values',
    () {
      final known = CloudFile(
        path: const ['Photos', 'known.jpg'],
        name: 'known.jpg',
        isDirectory: false,
        id: 'opaque-id',
        contentType: 'image/jpeg',
        size: 1024,
        favorite: true,
        etag: 'cached-revision',
        taken: DateTime.utc(2020),
        captureDay: 18262,
      );
      final files = reconcileAlbumMembers(
        [
          const CloudAlbumMember(
            reference: ['opaque-album', 'opaque-item'],
            id: 'opaque-id',
            size: 0,
            favorite: false,
          ),
          const CloudAlbumMember(
            reference: ['opaque-album', 'unknown'],
            contentType: 'video/mp4',
            displayName: 'Shared.mp4',
          ),
        ],
        [known],
      );
      expect(files.first.path, known.path);
      expect(files.first.contentType, known.contentType);
      expect(files.first.size, 0);
      expect(files.first.favorite, isFalse);
      expect(files.first.etag, 'cached-revision');
      expect(files.first.captureDay, known.captureDay);
      expect(files.last.name, 'Shared.mp4');
      expect(files.last.readOnly, isTrue);
      expect(files.last.albumReference, ['opaque-album', 'unknown']);
      expect(
        () => reconcileAlbumMembers([
          const CloudAlbumMember(reference: []),
        ], const []),
        throwsFormatException,
      );
    },
  );

  test(
    'timeline and favorites fetch only one page until scrolling requests another',
    () async {
      for (final destination in [Destination.timeline, Destination.favorites]) {
        final offsets = <int>[];
        final c =
            AppController(
                store: MemoryStore(),
                client: NextcloudClient(
                  transport: MockClient((request) async {
                    if (request.method == 'PROPFIND') {
                      return http.Response('', 404);
                    }
                    final offset = int.parse(
                      RegExp(
                        r'<sd:firstresult>(\d+)</sd:firstresult>',
                      ).firstMatch(request.body)!.group(1)!,
                    );
                    offsets.add(offset);
                    return http.Response(
                      page(offset, offset < 400 ? 200 : 1),
                      207,
                    );
                  }),
                ),
              )
              ..account = account
              ..timelineIndexAvailable = false;
        addTearDown(c.dispose);
        var sawFirstPage = false;
        c.addListener(() {
          if (c.items.length == 200 && !c.loading) {
            sawFirstPage = true;
          }
        });
        await c.select(destination);
        expect(offsets, [0]);
        expect(c.hasMore, isTrue);
        await c.loadNextPage();
        await c.loadNextPage();
        expect(offsets, [0, 200, 400], reason: destination.name);
        expect(c.items, hasLength(401));
        expect(sawFirstPage, isTrue);
        expect(c.hasMore, isFalse);
        expect(c.loadingMore, isFalse);
      }
    },
  );

  test(
    'a stale background page cannot replace a newly opened Drive folder',
    () async {
      final pending = Completer<http.Response>();
      var startedSecondPage = false;
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (request.method == 'PROPFIND') {
                    return http.Response(multistatus(''), 207);
                  }
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
            )
            ..account = account
            ..timelineIndexAvailable = false;
      addTearDown(c.dispose);
      await c.load();
      final timeline = c.loadNextPage();
      while (!startedSecondPage) {
        await Future<void>.delayed(Duration.zero);
      }
      await c.select(Destination.drive);
      pending.complete(http.Response(page(200, 1), 207));
      await timeline;
      expect(c.destination, Destination.drive);
      expect(c.items, isEmpty);
      expect(c.error, isNull);
      expect(c.loadingMore, isFalse);
    },
  );

  test('repeated server pages stop with an explicit error', () async {
    var calls = 0;
    final c =
        AppController(
            store: MemoryStore(),
            client: NextcloudClient(
              transport: MockClient((request) async {
                calls++;
                return http.Response(page(0, 200), 207);
              }),
            ),
          )
          ..account = account
          ..timelineIndexAvailable = false;
    addTearDown(c.dispose);
    await c.load();
    await c.loadNextPage();
    expect(calls, 2);
    expect(c.items, hasLength(200));
    expect(c.error, contains('repeated a page'));
    expect(c.loadingMore, isFalse);
  });

  test('first results remain cached when later pages fail', () async {
    final root = await Directory.systemTemp.createTemp(
      'ncloud-partial-listing-',
    );
    addTearDown(() => root.delete(recursive: true));
    final cache = LocalCache(() async => root);
    final first =
        AppController(
            store: MemoryStore(),
            cache: cache,
            client: NextcloudClient(
              transport: MockClient(
                (request) async =>
                    request.body.contains('<sd:firstresult>0</sd:firstresult>')
                    ? http.Response(page(0, 200), 207)
                    : http.Response('', 503),
              ),
            ),
          )
          ..account = account
          ..timelineIndexAvailable = false;
    await first.load();
    await first.loadNextPage();
    expect(first.error, isNotNull);
    first.dispose();
    final restored = AppController(
      store: MemoryStore(),
      cache: cache,
      client: NextcloudClient(
        transport: MockClient((_) async => http.Response('', 503)),
      ),
    )..account = account;
    addTearDown(restored.dispose);
    await restored.load();
    expect(restored.items, hasLength(200));
    expect(restored.error, isNotNull);
  });

  test(
    'cached cursor resumes; an explicit refresh resets the paging snapshot',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ncloud-full-listing-',
      );
      addTearDown(() => root.delete(recursive: true));
      final cache = LocalCache(() async => root);
      var refresh = false;
      final c =
          AppController(
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
            )
            ..account = account
            ..timelineIndexAvailable = false;
      addTearDown(c.dispose);
      await c.load();
      await c.loadNextPage();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      refresh = true;
      await c.load();
      expect(c.items, hasLength(200));
      expect(c.hasMore, isTrue);
      await c.loadNextPage();
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
        <d:propstat><d:prop><d:getcontenttype>image/jpeg</d:getcontenttype><oc:fileid>42</oc:fileid>
        <d:getetag>new-revision</d:getetag><d:getcontentlength>2048</d:getcontentlength><oc:favorite>0</oc:favorite></d:prop>
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
        etag: 'old-revision',
        size: 1024,
        favorite: true,
      );
      final files = reconcileAlbumMembers(
        await client.albumFiles(account, albums.first),
        [photo],
      );
      expect(files.first.path, photo.path);
      expect(files.first.name, photo.name);
      expect(files.first.readOnly, isFalse);
      expect(files.first.etag, 'new-revision');
      expect(files.first.size, 2048);
      expect(files.first.favorite, isFalse);
      expect(files.last.name, 'Shared.jpg');
      expect(files.last.readOnly, isTrue);
      expect(client.fileUri(account, files.last).pathSegments, [
        'nextcloud',
        'remote.php',
        'dav',
        'photos',
        'alice',
        'albums',
        'Trip & friends',
        '99',
      ]);
    },
  );

  test('renamed native album members resolve their current file path', () async {
    final client = NextcloudClient(
      transport: MockClient(
        (_) async => http.Response(
          '''<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns" xmlns:nc="http://nextcloud.org/ns">
        <d:response><d:href>/nextcloud/remote.php/dav/photos/alice/albums/Trip/42</d:href>
        <d:propstat><d:prop><oc:fileid>42</oc:fileid><nc:file-name>Renamed.jpg</nc:file-name></d:prop>
        <d:status>HTTP/1.1 200 OK</d:status></d:propstat></d:response></d:multistatus>''',
          207,
        ),
      ),
    );
    addTearDown(client.close);
    final files = reconcileAlbumMembers(
      await client.albumFiles(
        account,
        const CloudAlbum(
          name: 'Trip',
          count: 1,
          reference: ['photos', 'alice', 'albums', 'Trip'],
        ),
      ),
      [
        const CloudFile(
          path: ['Photos', 'Original.jpg'],
          name: 'Original.jpg',
          isDirectory: false,
          id: '42',
          contentType: 'image/jpeg',
        ),
      ],
    );
    expect(files.single.name, 'Renamed.jpg');
    expect(files.single.pending, isTrue);
    expect(files.single.id, '42');
    expect(files.single.readOnly, isFalse);
  });

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
    'first folders with media become Smart albums listed with server albums',
    (tester) async {
      final c = AppController(store: MemoryStore(), client: NextcloudClient());
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try demo'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Albums'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Library'), findsNothing);
      expect(find.text('Shared'), findsNothing);
      expect(find.text('Kyoto'), findsOneWidget);
      expect(find.text('Travel'), findsNothing);
      expect(find.text('Japan'), findsNothing);
      expect(find.text('Favorites'), findsOneWidget);
      expect(find.textContaining('Photo source:'), findsNothing);
      expect(find.text('Your albums'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Kyoto'), findsNothing);
      expect(find.text('Empty folder'), findsNothing);
      expect(c.nativeAlbums.single.name, 'Best days');
      expect(find.text('Map'), findsOneWidget);
      expect(find.text('All photos with a saved location'), findsNothing);
      expect(find.text('Shared with you'), findsNothing);
      expect(find.text('Cloud albums'), findsNothing);
      expect(find.text('Smart albums'), findsNothing);
      expect(find.text('Best days'), findsOneWidget);
      expect(find.byIcon(Icons.auto_awesome_outlined), findsWidgets);
      await tester.tap(find.text('Best days'));
      await tester.pumpAndSettle();
      expect(c.items, hasLength(3));
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Best days'), findsOneWidget);
      expect(find.text('Kyoto'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('View all Albums')));
      await tester.pumpAndSettle();
      expect(find.text('Dolomites'), findsOneWidget);
      expect(find.text('Best days'), findsOneWidget);
      expect(
        c.smartAlbums.map((a) => a.name),
        unorderedEquals(['Kyoto', 'Dolomites', 'Coast & country']),
      );
      await tester.tap(find.text('Kyoto'));
      await tester.pumpAndSettle();
      expect(c.directory, ['Photos', 'Travel', 'Japan', 'Kyoto']);
      expect(c.items, hasLength(4));
      expect(find.bySemanticsLabel('Alpine morning.jpg'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Albums expand to one grid and pinned shortcuts open directly', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = AppController(store: MemoryStore(), client: NextcloudClient());
    await tester.pumpWidget(NcloudApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Albums'));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('Kyoto')).dy, lessThan(550));
    expect(find.text('Pinned'), findsOneWidget);
    expect(find.byType(SliverGrid), findsNothing);
    await tester.tap(find.byKey(const ValueKey('View all Albums')));
    await tester.pumpAndSettle();
    expect(find.byType(SliverGrid), findsOneWidget);
    expect(find.text('Best days'), findsOneWidget);
    expect(find.text('Pinned'), findsNothing);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Pinned'), findsOneWidget);
    await tester.tap(find.text('Favorites'));
    await tester.pumpAndSettle();
    expect(c.destination, Destination.favorites);
    expect(c.items.every((f) => f.favorite), isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('timeline is content-first and view controls stay on demand', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      NcloudApp(
        controller: AppController(
          store: MemoryStore(),
          client: NextcloudClient(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try demo'));
    await tester.pumpAndSettle();
    final first = find.bySemanticsLabel('Alpine morning.jpg');
    expect(tester.getTopLeft(first).dy, lessThan(915 * .30));
    expect(find.textContaining('Load more'), findsNothing);
    expect(find.widgetWithText(ChoiceChip, 'Videos'), findsNothing);
    await tester.tap(find.byTooltip('View options'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(ChoiceChip, 'Videos'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(15, 20));
    await tester.pumpAndSettle();
    expect(find.bySemanticsLabel('Wild coast.mp4'), findsOneWidget);
    expect(find.bySemanticsLabel('Alpine morning.jpg'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
