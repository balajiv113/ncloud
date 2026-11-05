import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/file_store.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/media_tile.dart';
import 'package:ncloud/nextcloud_client.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account, multistatus, responseEntry;
import 'preview_test.dart' show photo, png;

class _SqliteFailure extends DatabaseException {
  _SqliteFailure(this.code) : super('SQL failure with private arguments');
  final int code;

  @override
  int getResultCode() => code;

  @override
  Object? get result => null;
}

class _FailingFactory implements DatabaseFactory {
  _FailingFactory(
    this.error, {
    required this.failures,
    this.duringTransaction = false,
  });
  final Object error;
  final bool duringTransaction;
  int failures;
  int attempts = 0;
  int transactions = 0;

  @override
  Future<Database> openDatabase(
    String path, {
    OpenDatabaseOptions? options,
  }) async {
    attempts++;
    if (!duringTransaction && failures > 0) {
      failures--;
      throw error;
    }
    final db = await databaseFactoryFfi.openDatabase(path, options: options);
    return duringTransaction ? _FailingTransaction(db, this) : db;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailingTransaction implements Database {
  _FailingTransaction(this.database, this.factory);
  @override
  final Database database;
  final _FailingFactory factory;

  @override
  Future<T> transaction<T>(
    Future<T> Function(Transaction) action, {
    bool? exclusive,
  }) => database.transaction((txn) async {
    factory.transactions++;
    final value = await action(txn);
    if (factory.failures > 0) {
      factory.failures--;
      throw factory.error;
    }
    return value;
  }, exclusive: exclusive);

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) => database.query(
    table,
    distinct: distinct,
    columns: columns,
    where: where,
    whereArgs: whereArgs,
    groupBy: groupBy,
    having: having,
    orderBy: orderBy,
    limit: limit,
    offset: offset,
  );

  @override
  Future<void> close() => database.close();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalCache cache;

  setUp(() async {
    root = await Directory(
      '.dart_tool/ncloud-cache-tests/${DateTime.now().microsecondsSinceEpoch}',
    ).absolute.create(recursive: true);
    cache = LocalCache(
      () async => Directory('${root.path}/cache'),
      databaseFactory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await cache.close();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('cache digests are stable and distinguish keys', () {
    expect(cacheDigest('a'), cacheDigest('a'));
    expect(cacheDigest('a'), isNot(cacheDigest('b')));
    expect(cacheDigest('a'), hasLength(32));
  });

  test('thumbnail writes leave headroom and retain library metadata', () async {
    cache = LocalCache(
      () async => Directory('${root.path}/cache'),
      budget: 1024 * 1024,
    );
    await cache.writeDocument('library', {'cached': true});
    for (final key in ['old', 'middle', 'recent']) {
      await cache.writeThumbnail(key, Uint8List(300 * 1024));
    }
    expect(await cache.readThumbnail('old'), isNull);
    expect(await cache.readThumbnail('recent'), isNotNull);
    expect(await cache.readDocument('library'), {'cached': true});
    expect(await cache.size(), lessThanOrEqualTo(1024 * 1024 * 0.9));
    expect(cache.writeError, isNull);
  });

  for (final error in [
    _SqliteFailure(13),
    const FileSystemException('full', 'private-path', OSError('full', 28)),
  ]) {
    test(
      'disk-full metadata writes evict oldest previews and retry: $error',
      () async {
        final factory = _FailingFactory(error, failures: 1);
        cache = LocalCache(
          () async => Directory('${root.path}/cache'),
          budget: 10 * 1024 * 1024,
          databaseFactory: factory,
        );
        final original = await cache.original('saved', 'photo.jpg');
        await original.writeAsBytes(png);
        await cache.writeOfflineListing('offline', [photo()]);
        await cache.writeThumbnail('old', Uint8List(1024 * 1024));
        await cache.writeThumbnail('recent', Uint8List(1024 * 1024));
        final old = File('${root.path}/cache/thumbs/${cacheDigest('old')}');
        await old.setLastModified(DateTime.utc(2020));
        // Reindex disk LRU order, as after restarting an already-full device.
        await cache.close();
        cache = LocalCache(
          () async => Directory('${root.path}/cache'),
          budget: 10 * 1024 * 1024,
          databaseFactory: factory,
        );
        await cache.writeDocument('metadata', {'saved': true});
        expect(factory.attempts, 2);
        expect(cache.writeError, isNull);
        expect(await cache.readDocument('metadata'), {'saved': true});
        expect(await cache.readThumbnail('old'), isNull);
        expect(await cache.readThumbnail('recent'), isNotNull);
        expect(await original.readAsBytes(), png);
        expect(await cache.readOfflineListing('offline'), hasLength(1));
      },
    );
  }

  test('busy database retries once without deleting previews', () async {
    final factory = _FailingFactory(_SqliteFailure(5), failures: 1);
    cache = LocalCache(
      () async => Directory('${root.path}/cache'),
      databaseFactory: factory,
    );
    await cache.writeThumbnail('keep', Uint8List(1024));
    await cache.writeDocument('metadata', {'saved': true});
    expect(factory.attempts, 2);
    expect(cache.writeError, isNull);
    expect(await cache.readThumbnail('keep'), isNotNull);
    expect(await cache.readDocument('metadata'), {'saved': true});
  });

  test(
    'offline membership metadata also reclaims previews on disk full',
    () async {
      var attempts = 0;
      final saved = Directory('${root.path}/saved');
      final original = File('${saved.path}/originals/keep.jpg');
      await original.parent.create(recursive: true);
      await original.writeAsBytes(png);
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        locateDownloads: () async {
          if (attempts++ == 0) {
            throw const FileSystemException('full', '', OSError('full', 28));
          }
          return saved;
        },
      );
      await cache.writeThumbnail('disposable', Uint8List(1024));
      await cache.writeOfflineListing('offline', [photo()]);
      expect(attempts, 2);
      expect(await cache.readThumbnail('disposable'), isNull);
      expect(await cache.readOfflineListing('offline'), hasLength(1));
      expect(await original.readAsBytes(), png);
    },
  );

  test(
    'full database transactions roll back and retry before acknowledging',
    () async {
      final factory = _FailingFactory(
        _SqliteFailure(13),
        failures: 1,
        duringTransaction: true,
      );
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 10 * 1024 * 1024,
        databaseFactory: factory,
      );
      await cache.writeThumbnail('disposable', Uint8List(1024));
      final store = FileStore()..putFolder(['Photos'], [photo()]);
      await cache.writeLibrary('library', store);
      expect(factory.transactions, 2);
      expect(cache.writeError, isNull);
      expect(store.persistenceChanges().files, isEmpty);
      expect(await cache.readThumbnail('disposable'), isNull);
      await cache.close();
      cache = LocalCache(() async => Directory('${root.path}/cache'));
      final restored = await cache.readDocument('library');
      expect(restored!['files'] as List, hasLength(1));
    },
  );

  test(
    'unrecoverable full storage preserves dirty metadata and originals',
    () async {
      final factory = _FailingFactory(_SqliteFailure(13), failures: 10);
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 10 * 1024 * 1024,
        databaseFactory: factory,
      );
      final original = await cache.original('saved', 'photo.jpg');
      await original.writeAsBytes(png);
      await cache.writeThumbnail('disposable', Uint8List(1024));
      final store = FileStore()..putFolder(['Photos'], [photo()]);
      await cache.writeLibrary('library', store);
      expect(factory.attempts, 2);
      expect(cache.writeError, contains('SQLite 13'));
      expect(cache.writeError, isNot(contains('private')));
      expect(store.persistenceChanges().files, isNotEmpty);
      expect(await original.readAsBytes(), png);
      factory.failures = 0;
      await cache.writeLibrary('library', store);
      expect(store.persistenceChanges().files, isEmpty);
      expect(store.persistenceChanges().folders, isEmpty);
      await cache.close();
      cache = LocalCache(() async => Directory('${root.path}/cache'));
      expect(await cache.readDocument('library'), isNotNull);
    },
  );

  test(
    'non-storage errors do not evict previews or expose SQL arguments',
    () async {
      final factory = _FailingFactory(_SqliteFailure(19), failures: 1);
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        databaseFactory: factory,
      );
      await cache.writeThumbnail('keep', Uint8List(1024));
      await cache.writeDocument('metadata', {'saved': true});
      expect(factory.attempts, 1);
      expect(cache.writeError, contains('SQLite 19'));
      expect(cache.writeError, isNot(contains('storage is full')));
      expect(cache.writeError, isNot(contains('private')));
      expect(await cache.readThumbnail('keep'), isNotNull);
    },
  );

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
    await cache.writeThumbnail('k', Uint8List.fromList(png), version: 'e1');
    final stored = await cache.readThumbnail('k');
    expect(stored!.bytes, png);
    expect(stored.version, 'e1');
    await cache.writeListing('l', [photo()]);
    expect((await cache.readListing('l'))!.single.name, 'Sun & sky.png');
    expect(await cache.size(), greaterThan(png.length));
    await cache.clear();
    expect(await cache.readThumbnail('k'), isNull);
    expect(await cache.size(), 0);
  });

  test(
    'cache write failures notify and explicit clear failures propagate',
    () async {
      final broken = LocalCache(() async => throw const FileSystemException());
      String? warning;
      broken.onWriteError = (message) => warning = message;
      await broken.writeThumbnail('k', Uint8List(1));
      expect(warning, contains('storage'));
      expect(broken.writeError, warning);
      expect(await broken.readThumbnail('k'), isNull);
      expect(await broken.readListing('k'), isNull);
      await expectLater(broken.clear(), throwsA(isA<FileSystemException>()));
    },
  );

  test(
    'one budget evicts oldest previews across metadata and thumbnails',
    () async {
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 256 * 1024,
      );
      await cache.writeThumbnail('old', Uint8List(100 * 1024));
      await cache.writeThumbnail('recent', Uint8List(100 * 1024));
      await cache.writeDocument('metadata', {'value': 'a' * 100});
      expect(await cache.size(), lessThanOrEqualTo(256 * 1024));
      expect(await cache.readThumbnail('old'), isNull);
      expect(await cache.readThumbnail('recent'), isNotNull);
      expect(await cache.readDocument('metadata'), {'value': 'a' * 100});
    },
  );

  test(
    'concurrent overwrites retain exact accounting and enforce the cap',
    () async {
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 400,
      );
      await Future.wait([
        for (var i = 0; i < 10; i++)
          cache.writeThumbnail('same', Uint8List(100)),
      ]);
      expect(await cache.size(), 105);
      await cache.writeThumbnail('next', Uint8List(100));
      expect(await cache.size(), 210);
      await cache.writeThumbnail('oversized', Uint8List(500));
      expect(await cache.size(), lessThanOrEqualTo(400));
    },
  );

  test(
    'restart trims all browsing categories and removes interrupted writes',
    () async {
      await cache.writeListing('list', [photo()]);
      await cache.writeDocument('doc', {'value': 'a' * 100});
      await cache.writeThumbnail('thumb', Uint8List(100));
      final abandoned = File('${root.path}/cache/thumbs/abandoned.part');
      await abandoned.writeAsBytes(Uint8List(1000));
      final size = await cache.size();
      await cache.close();
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 200,
      );
      await cache.trim();
      expect(size, greaterThan(200));
      expect(await cache.size(), lessThanOrEqualTo(200));
      expect(await abandoned.exists(), isFalse);
    },
  );

  test(
    'LRU reads protect old previews without touching disk on every hit',
    () async {
      await cache.writeThumbnail('read', Uint8List(100));
      await cache.writeThumbnail('other', Uint8List(100));
      final readFile = File('${root.path}/cache/thumbs/${cacheDigest('read')}');
      final otherFile = File(
        '${root.path}/cache/thumbs/${cacheDigest('other')}',
      );
      await readFile.setLastModified(DateTime.utc(2020));
      await otherFile.setLastModified(DateTime.utc(2021));
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 300,
      );
      await cache.trim();
      await cache.readThumbnail('read');
      await cache.writeThumbnail('new', Uint8List(100));
      expect(await cache.readThumbnail('other'), isNull);
      expect(await cache.readThumbnail('read'), isNotNull);
    },
  );

  test('legacy compressed JSON migrates lazily into SQLite metadata', () async {
    final large = {'rows': List.filled(500, 'repeated library metadata')};
    final file = File(
      '${root.path}/cache/indexes/${cacheDigest('large')}.json',
    );
    await file.parent.create(recursive: true);
    await file.writeAsBytes(gzip.encode(utf8.encode(jsonEncode(large))));
    expect(await cache.readDocument('large'), large);
    expect(await file.exists(), isFalse);
    await cache.writeListing('large-list', List.filled(50, photo()));
    expect(await cache.readListing('large-list'), hasLength(50));
    await cache.writeDocument('small', {'value': 1});
    final small = File(
      '${root.path}/cache/indexes/${cacheDigest('small')}.json',
    );
    expect(await small.exists(), isFalse);
    expect(await cache.readDocument('small'), {'value': 1});
    expect(await File('${root.path}/cache/catalogue.sqlite3').exists(), isTrue);
  });

  test(
    'saved originals and membership survive eviction, clear and restart',
    () async {
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 100,
      );
      final original = await cache.original('saved', 'photo.jpg');
      await original.writeAsBytes(Uint8List(1000));
      await cache.writeOfflineListing('offline', [photo()]);
      await cache.writeThumbnail('oversized', Uint8List(500));
      expect(await cache.size(), lessThanOrEqualTo(100));
      expect(await cache.downloadSize(), greaterThanOrEqualTo(1000));
      await cache.clear();
      cache = LocalCache(() async => Directory('${root.path}/cache'));
      expect(await original.length(), 1000);
      expect(await cache.readOfflineListing('offline'), hasLength(1));
      expect(await cache.size(), 0);
      await cache.clearAll();
      expect(await original.exists(), isFalse);
      expect(await cache.readOfflineListing('offline'), isEmpty);
    },
  );

  test(
    'legacy downloads and manifest migrate before browsing eviction',
    () async {
      final legacy = Directory('${root.path}/cache/originals');
      await legacy.create(recursive: true);
      final oldOriginal = File('${legacy.path}/${cacheDigest('saved')}.jpg');
      await oldOriginal.writeAsBytes(png);
      await cache.writeListing('offline', [photo()]);
      await cache.close();
      cache = LocalCache(
        () async => Directory('${root.path}/cache'),
        budget: 1,
      );
      expect(await cache.readOfflineListing('offline'), hasLength(1));
      await cache.trim();
      await cache.clear();
      expect(await oldOriginal.exists(), isFalse);
      expect(
        await (await cache.original('saved', 'photo.jpg')).readAsBytes(),
        png,
      );
      expect(await cache.readOfflineListing('offline'), hasLength(1));
    },
  );

  test('failed download directory initialization can be retried', () async {
    var attempts = 0;
    cache = LocalCache(
      () async => Directory('${root.path}/cache'),
      locateDownloads: () async {
        if (attempts++ == 0) throw const FileSystemException('unavailable');
        return Directory('${root.path}/saved');
      },
    );
    await expectLater(
      cache.original('k', 'photo.jpg'),
      throwsA(isA<FileSystemException>()),
    );
    final file = await cache.original('k', 'photo.jpg');
    await file.writeAsBytes(png);
    expect(await file.exists(), isTrue);
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

  testWidgets('a visible thumbnail reloads when its indexed revision changes', (
    tester,
  ) async {
    var calls = 0;
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((_) async {
          calls++;
          return http.Response.bytes(png, 200);
        }),
      ),
    )..account = account;
    addTearDown(controller.dispose);
    Widget tile(String revision) => MaterialApp(
      home: SizedBox(
        width: 128,
        height: 128,
        child: MediaTile(
          controller: controller,
          file: photo().withCaptureDate(
            DateTime.utc(2026, 1, 1),
            revision,
            day: 20454,
          ),
        ),
      ),
    );
    Future<void> waitForPreview(int expectedCalls) async {
      for (var attempt = 0; attempt < 30; attempt++) {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        });
        await tester.pump();
        if (calls == expectedCalls &&
            find.byType(Image).evaluate().isNotEmpty) {
          break;
        }
      }
    }

    await tester.pumpWidget(tile('first'));
    await waitForPreview(1);
    expect(calls, 1);
    await tester.pumpWidget(tile('edited'));
    await waitForPreview(2);
    expect(calls, 2);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'viewer keeps the grid thumbnail while its larger preview loads',
    (tester) async {
      final large = Completer<http.Response>();
      final controller = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient(
            (request) async => request.url.queryParameters['x'] == '1280'
                ? large.future
                : http.Response.bytes(png, 200),
          ),
        ),
      )..account = account;
      await tester.runAsync(() => controller.preview(photo()));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaTile(
            file: photo(),
            controller: controller,
            previewSize: 1280,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      final image =
          tester.widget<Image>(find.byType(Image)).image as ResizeImage;
      expect((image.imageProvider as MemoryImage).bytes, png);
      expect(controller.previewCurrent(photo(), size: 1280), isFalse);
      large.complete(http.Response.bytes(png, 200));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      await tester.pumpAndSettle();
      expect(controller.previewCurrent(photo(), size: 1280), isTrue);
      expect(find.byType(Image), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

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
        await controller.clearCache();
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
