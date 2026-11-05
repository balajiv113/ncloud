import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/media_tile.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;
import 'preview_test.dart' show photo, png;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ncloud-cache-test');
    cache = LocalCache(() async => Directory('${root.path}/cache'));
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('cache digests are stable and distinguish keys', () {
    expect(cacheDigest('a'), cacheDigest('a'));
    expect(cacheDigest('a'), isNot(cacheDigest('b')));
    expect(cacheDigest('a'), hasLength(32));
  });

  test('files round-trip through JSON', () {
    final file = CloudFile(
      path: const ['Photos', 'Sun & sky.png'],
      name: 'Sun & sky.png',
      isDirectory: false,
      contentType: 'image/png',
      size: 99,
      modified: DateTime.utc(2026, 11, 4, 1, 2, 3),
      id: '7',
      favorite: true,
    );
    final copy = CloudFile.fromJson(file.toJson());
    expect(copy.path, file.path);
    expect(copy.name, file.name);
    expect(copy.contentType, file.contentType);
    expect(copy.size, 99);
    expect(copy.modified, file.modified);
    expect(copy.id, '7');
    expect(copy.favorite, isTrue);
  });

  test('thumbnails and listings persist, report size and clear', () async {
    expect(await cache.readThumbnail('k'), isNull);
    await cache.writeThumbnail('k', Uint8List.fromList(png));
    expect(await cache.readThumbnail('k'), png);
    await cache.writeListing('l', [photo()]);
    expect((await cache.readListing('l'))!.single.name, 'Sun & sky.png');
    expect(await cache.size(), greaterThan(png.length));
    await cache.clear();
    expect(await cache.readThumbnail('k'), isNull);
    expect(await cache.size(), 0);
  });

  test('cache failures are silent when no directory is available', () async {
    final broken = LocalCache(() async => throw const FileSystemException());
    await broken.writeThumbnail('k', Uint8List(1));
    expect(await broken.readThumbnail('k'), isNull);
    expect(await broken.readListing('k'), isNull);
    await broken.clear();
  });

  test('original cache names keep a safe extension', () async {
    final file = await cache.original('x', 'clip.MP4');
    expect(file.path, endsWith('.MP4'));
    final odd = await cache.original('y', '../evil');
    expect(odd.path, isNot(contains('..')));
  });

  test(
    'Memories metadata preserves originals saved by previous previews',
    () async {
      final old = photo();
      final key =
          'original|${account.server}|${account.userId}|${old.id ?? old.key}|'
          '${old.modified?.microsecondsSinceEpoch}|${old.size}';
      final saved = await cache.original(key, old.name);
      await saved.writeAsBytes(png);
      final c = AppController(store: MemoryStore(), cache: cache)
        ..account = account;
      addTearDown(c.dispose);
      final indexed = old.withCaptureDate(
        DateTime.utc(2026, 1, 1),
        'known-etag',
        day: 20454,
      );
      expect((await c.offlineCopy(indexed))?.path, saved.path);
    },
  );

  test(
    'quoted DAV and Memories etags reuse previews while edited revisions invalidate them',
    () async {
      var calls = 0;
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((_) async {
            calls++;
            return http.Response.bytes(png, 200);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      final file = photo();
      CloudFile revision(String etag) =>
          file.withCaptureDate(DateTime.utc(2026, 1, 1), etag, day: 20454);
      await c.preview(revision('"same"'));
      await c.preview(revision('same'));
      expect(calls, 1);
      await c.preview(revision('edited'));
      expect(calls, 2);
    },
  );

  test('previews are served from disk across app restarts', () async {
    var calls = 0;
    AppController controller() => AppController(
      store: MemoryStore(),
      cache: cache,
      client: NextcloudClient(
        transport: MockClient((request) async {
          calls++;
          return http.Response.bytes(png, 200);
        }),
      ),
    )..account = account;
    final first = controller();
    expect(await first.preview(photo()), png);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.dispose();
    final second = controller();
    addTearDown(second.dispose);
    expect(await second.preview(photo()), png);
    expect(calls, 1);
    expect(await second.preview(photo(), retry: true), png);
    expect(calls, 2);
  });

  test('cached listings show instantly and survive refresh errors', () async {
    var fail = false;
    AppController controller() => AppController(
      store: MemoryStore(),
      cache: cache,
      client: NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.contains('/apps/memories/')) {
            return http.Response('', 404);
          }
          if (fail) return http.Response('', 503);
          return http.Response(multistatus(responseEntry()), 207);
        }),
      ),
    )..account = account;
    final first = controller();
    await first.load();
    expect(first.items.single.name, 'Beach & sun.jpg');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    first.dispose();

    fail = true;
    final second = controller();
    addTearDown(second.dispose);
    var sawRefreshing = false;
    second.addListener(() {
      if (second.refreshing && second.items.isNotEmpty) sawRefreshing = true;
    });
    await second.load();
    expect(sawRefreshing, isTrue);
    expect(second.items.single.name, 'Beach & sun.jpg');
    expect(second.error, isNotNull);
    expect(second.refreshing, isFalse);
  });

  test('video streams keep credentials in headers, not the URL', () {
    final c = AppController(store: MemoryStore())..account = account;
    addTearDown(c.dispose);
    final source = c.streamSource(photo())!;
    expect(source.uri.userInfo, isEmpty);
    expect(source.uri.path, contains('/remote.php/dav/files/alice/Photos/'));
    expect(source.headers['Authorization'], account.authorization);
  });

  testWidgets(
    'saved originals reopen offline without requesting image previews',
    (tester) async {
      var networkCalls = 0;
      final controller = AppController(
        store: MemoryStore(),
        cache: cache,
        client: NextcloudClient(
          transport: MockClient((_) async {
            networkCalls++;
            return http.Response.bytes(png, 200);
          }),
        ),
      )..account = account;
      addTearDown(controller.dispose);
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (_) async => root.path,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.runAsync(() async {
        await controller.saveOffline(photo());
        await controller.selectTab(6);
      });
      expect(controller.items.single.key, photo().key);
      expect(networkCalls, 1);
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 128,
            height: 128,
            child: MediaTile(
              file: controller.items.single,
              controller: controller,
              previewSize: 1280,
            ),
          ),
        ),
      );
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        if (find.byType(Image).evaluate().isNotEmpty) break;
      }
      expect(find.byType(Image), findsOneWidget);
      final image = tester.widget<Image>(find.byType(Image));
      expect((image.image as ResizeImage).imageProvider, isA<FileImage>());
      expect(networkCalls, 1);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() async {
        await (await controller.offlineCopy(photo()))!.delete();
        await controller.load();
      });
      expect(controller.items, isEmpty);
    },
  );
}
