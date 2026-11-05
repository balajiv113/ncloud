import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;

void main() {
  test(
    'incoming folder API uses recipient paths and excludes self-owned shares',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.url.queryParameters['shared_with_me'], 'true');
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok'},
                'data': [
                  {
                    'path': '/Shared/Mounted name',
                    'file_target': '/Old name',
                    'item_type': 'folder',
                    'uid_owner': 'bob',
                    'uid_file_owner': 'bob',
                    'share_type': 0,
                  },
                  {
                    'path': '/Shared/Mounted name',
                    'item_type': 'folder',
                    'uid_owner': 'bob',
                    'share_type': 1,
                  },
                  {
                    'path': '/Shared/Mounted name/Nested',
                    'item_type': 'folder',
                    'uid_owner': 'bob',
                    'share_type': 0,
                  },
                  {
                    'path': '/Outgoing',
                    'item_type': 'folder',
                    'uid_owner': 'alice',
                    'share_type': 0,
                  },
                  {
                    'path': '/My reshared folder',
                    'item_type': 'folder',
                    'uid_owner': 'bob',
                    'uid_file_owner': 'alice',
                    'share_type': 0,
                  },
                  {
                    'path': '/Public',
                    'item_type': 'folder',
                    'uid_owner': 'bob',
                    'share_type': 3,
                  },
                  {
                    'path': '/Photo.jpg',
                    'item_type': 'file',
                    'uid_owner': 'bob',
                    'share_type': 0,
                  },
                ],
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      expect(await client.incomingSharedFolders(account), [
        ['Shared', 'Mounted name'],
      ]);
    },
  );

  testWidgets(
    'floating dock compacts on scroll and restores without moving content',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = AppController(store: MemoryStore());
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try demo'));
      await tester.pumpAndSettle();
      final dock = find.byKey(const ValueKey('navigation-dock'));
      expect(tester.getSize(dock).height, 78);
      for (final tab in [0, 4, 1]) {
        final size = tester.getSize(find.byKey(ValueKey('navigate-$tab')));
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
      }
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pumpAndSettle();
      expect(tester.getSize(dock).height, 60);
      expect(tester.getSize(dock).width, lessThanOrEqualTo(268));
      final position = tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position;
      final offset = position.pixels;
      await tester.pump(const Duration(seconds: 1));
      expect(
        position.pixels,
        offset,
        reason: 'dock resizing must not shift the scroll extent',
      );
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 180));
      await tester.pumpAndSettle();
      expect(tester.getSize(dock).height, 78);
      await tester.tap(find.byTooltip('Timeline'));
      await tester.pumpAndSettle();
      await tester.tap(find.bySemanticsLabel('Alpine morning.jpg'));
      await tester.pumpAndSettle();
      expect(dock, findsNothing, reason: 'viewer stays immersive');
      await tester.tap(find.byTooltip('Back to library'));
      await tester.pumpAndSettle();
      expect(dock, findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dock honors reduced motion and retains compact tap targets', (
    tester,
  ) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(
      NcloudApp(controller: AppController(store: MemoryStore())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try demo'));
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
    await tester.pumpAndSettle();
    final dock = tester.widget<AnimatedContainer>(
      find.byKey(const ValueKey('navigation-dock')),
    );
    expect(dock.duration, Duration.zero);
    for (final tab in [0, 4, 1]) {
      final size = tester.getSize(find.byKey(ValueKey('navigate-$tab')));
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
    }
    await tester.tap(find.byTooltip('Albums'));
    await tester.pumpAndSettle();
    expect(find.text('Smart albums'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('trash restore targets a child of the restore collection', () async {
    final client = NextcloudClient(
      transport: MockClient((request) async {
        expect(request.method, 'MOVE');
        expect(Uri.parse(request.headers['Destination']!).pathSegments, [
          'nextcloud',
          'remote.php',
          'dav',
          'trashbin',
          'alice',
          'restore',
          'photo.jpg.d123',
        ]);
        expect(request.headers['Overwrite'], isNull);
        return http.Response('', 201);
      }),
    );
    addTearDown(client.close);
    await client.restore(
      account,
      const TrashEntry(
        key: 'photo.jpg.d123',
        name: 'photo.jpg',
        originalPath: 'Photos/photo.jpg',
      ),
    );
  });
  test(
    'demo albums are actual folders and copy/move/rename/restore update paths',
    () async {
      final c = AppController(store: MemoryStore());
      addTearDown(c.dispose);
      await c.initialize();
      c.enterDemo();
      await c.selectTab(4);
      final photos = (await c.folderContents(
        [],
      )).firstWhere((f) => f.name == 'Photos');
      expect(await c.albumCover(photos), isNotNull);
      await c.openSmartAlbum(['Photos', 'Travel', 'Japan', 'Kyoto']);
      expect(c.tab, 4);
      final original = c.items.firstWhere((f) => f.isImage);
      expect(
        await c.organize([original], 'copy', destination: ['Documents']),
        isTrue,
      );
      expect(
        (await c.folderContents([
          'Documents',
        ])).any((f) => f.name == original.name),
        isTrue,
      );
      expect(
        await c.organize([original], 'rename', newName: 'Renamed.jpg'),
        isTrue,
      );
      final renamed = c.items.firstWhere((f) => f.name == 'Renamed.jpg');
      expect(
        await c.organize([renamed], 'move', destination: ['Weekend escapes']),
        isTrue,
      );
      expect(c.items.any((f) => f.name == 'Renamed.jpg'), isFalse);
      final moved = (await c.folderContents([
        'Weekend escapes',
      ])).firstWhere((f) => f.name == 'Renamed.jpg');
      expect(await c.organize([moved], 'delete'), isTrue);
      final trash = await c.trash();
      expect(trash.single.name, 'Renamed.jpg');
      await c.restore(trash.single);
      expect(await c.trash(), isEmpty);
      expect(
        (await c.folderContents([
          'Weekend escapes',
        ])).any((f) => f.name == 'Renamed.jpg'),
        isTrue,
      );
      expect(
        await c.organize([photos], 'move', destination: ['Photos']),
        isFalse,
      );
      expect(c.error, contains('inside itself'));
    },
  );

  test(
    'pagination retains items, uses offset and stops after the final page',
    () async {
      final offsets = <int>[];
      final transport = MockClient((request) async {
        final offset = int.parse(
          RegExp(
            r'<sd:firstresult>(\d+)</sd:firstresult>',
          ).firstMatch(request.body)!.group(1)!,
        );
        offsets.add(offset);
        final count = offset == 0 ? 200 : 1;
        return http.Response(
          multistatus(
            List.generate(
              count,
              (i) => responseEntry(
                href:
                    '/nextcloud/remote.php/dav/files/alice/Photos/photo-${offset + i}.jpg',
              ),
            ).join(),
          ),
          207,
        );
      });
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(transport: transport),
            )
            ..account = account
            ..memoriesAvailable = false;
      addTearDown(c.dispose);
      await c.load();
      expect(offsets, [0]);
      expect(c.hasMore, isTrue);
      await c.loadNextPage();
      expect(offsets, [0, 200]);
      expect(c.items, hasLength(201));
      expect(c.hasMore, isFalse);
      expect(offsets, hasLength(2));
    },
  );

  test(
    'MOVE/COPY refuse overwrites and preserve encoded destinations',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.method, 'COPY');
          expect(request.headers['Overwrite'], 'F');
          final target = Uri.parse(request.headers['Destination']!);
          expect(target.pathSegments.last, 'photo #1.jpg');
          expect(request.followRedirects, isFalse);
          return http.Response('', 201);
        }),
      );
      addTearDown(client.close);
      final file = CloudFile(
        path: const ['photo.jpg'],
        name: 'photo.jpg',
        isDirectory: false,
      );
      await client.transfer(account, file, [
        'Album & family',
        'photo #1.jpg',
      ], copy: true);
      final folder = CloudFile(
        path: const ['Photos'],
        name: 'Photos',
        isDirectory: true,
      );
      await expectLater(
        client.transfer(account, folder, ['Photos', 'child']),
        throwsA(isA<CloudException>()),
      );
    },
  );

  test(
    'sharing creates read-only password/expiry links and rejects OCS errors',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.headers['OCS-APIRequest'], 'true');
          final body = Uri.splitQueryString(request.body);
          expect(body['permissions'], '1');
          expect(body['shareType'], '3');
          expect(body['path'], '/Photos/a & b.jpg');
          expect(body['password'], 'fixture');
          expect(body['expireDate'], '2027-01-02');
          return http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'ok'},
                'data': {
                  'id': 42,
                  'url': 'https://cloud.example/s/abc',
                  'password': 'hash',
                  'expiration': '2027-01-02',
                },
              },
            }),
            200,
          );
        }),
      );
      addTearDown(client.close);
      final result = await client.createShare(
        account,
        const CloudFile(
          path: ['Photos', 'a & b.jpg'],
          name: 'a & b.jpg',
          isDirectory: false,
        ),
        password: 'fixture',
        expires: DateTime(2027, 1, 2),
      );
      expect(result.id, '42');
      expect(result.passwordProtected, isTrue);
      final failed = NextcloudClient(
        transport: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'ocs': {
                'meta': {'status': 'failure'},
                'data': [],
              },
            }),
            200,
          ),
        ),
      );
      addTearDown(failed.close);
      await expectLater(
        failed.shares(
          account,
          const CloudFile(path: ['a'], name: 'a', isDirectory: false),
        ),
        throwsA(isA<CloudException>()),
      );
    },
  );

  testWidgets('albums open folders, selection favorites and viewer swipes', (
    tester,
  ) async {
    final c = AppController(store: MemoryStore());
    await tester.pumpWidget(NcloudApp(controller: c));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try demo'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Albums'));
    await tester.pumpAndSettle();
    expect(find.text('Smart albums'), findsOneWidget);
    expect(find.text('Empty folder'), findsNothing);
    expect(find.text('Japan'), findsNothing);
    await tester.ensureVisible(find.text('Travel'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();
    expect(c.tab, 4);
    expect(c.directory, ['Photos', 'Travel']);
    final image = find.bySemanticsLabel('Alpine morning.jpg');
    await tester.longPress(image);
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsOneWidget);
    await tester.tap(find.byTooltip('Favorite selected'));
    await tester.pumpAndSettle();
    expect(find.text('1 selected'), findsNothing);
    await tester.tap(image);
    await tester.pumpAndSettle();
    expect(find.text('1 of 8'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(-700, 0));
    await tester.pumpAndSettle();
    expect(find.text('2 of 8'), findsOneWidget);
    await tester.tap(find.byTooltip('Back to library'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('new library has no overflow on small phones and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 1.5;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    final c = AppController(store: MemoryStore());
    await tester.pumpWidget(NcloudApp(controller: c));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Try demo'));
    await tester.tap(find.text('Try demo'));
    await tester.pumpAndSettle();
    for (final label in ['Albums', 'Drive', 'Timeline']) {
      await tester.tap(find.byTooltip(label));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: label);
    }
  });
}
