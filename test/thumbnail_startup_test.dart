import 'dart:io';
import 'dart:math' as math;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/features/library/domain/thumbnail_repository.dart';
import 'package:ncloud/models.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account;
import 'preview_test.dart' show photo, png;

class _Backend implements CloudBackend {
  int running = 0;
  int requests = 0;
  int peak = 0;

  @override
  void close() {}

  @override
  Future<List<Uint8List?>> previews(
    Account account,
    List<CloudFile> files, {
    int size = 384,
  }) async {
    requests++;
    throw const CloudException('Server unavailable');
  }

  @override
  Future<List<List<String>>> incomingSharedFolders(Account account) async => [
    for (final name in ['d', 'a', 'f', 'c', 'e', 'b', 'g']) ['Shared', name],
  ];

  @override
  Future<TimelineResult?> timeline(Account account, TimelineQuery query) async {
    peak = math.max(peak, ++running);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    running--;
    final name = query.path.last;
    return TimelineResult.page([
      CloudFile(
        path: [...query.path, '$name.jpg'],
        name: '$name.jpg',
        isDirectory: false,
        contentType: 'image/jpeg',
        id: name,
      ),
    ], null);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late Directory dir;
  late LocalCache cache;
  late _Backend backend;
  File? saved;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ncloud-hydrate-');
    saved = null;
    cache = LocalCache(() async => dir);
  });

  tearDown(() async {
    await cache.close();
    await dir.delete(recursive: true);
  });

  ThumbnailRepository repository() => ThumbnailRepository(
    client: backend = _Backend(),
    cache: cache,
    account: () => account,
    active: () => true,
    batchAvailable: () => false,
    offlineOriginal: (_) async => saved,
  );

  test(
    'hydrate loads stored thumbnails into memory without the network',
    () async {
      final repo = repository();
      final key = repo.key(photo(etag: 'v1'), 384)!;
      await cache.writeThumbnail(key, png, version: 'v1');
      expect(repo.cached(photo(etag: 'v1')), isNull);
      await repo.hydrate([photo(etag: 'v1')]);
      expect(repo.cached(photo(etag: 'v1')), png);
      expect(repo.current(photo(etag: 'v1')), isTrue);
    },
  );

  test(
    'hydrate keeps an older revision but does not treat it as current',
    () async {
      final repo = repository();
      await cache.writeThumbnail(repo.key(photo(), 384)!, png, version: 'old');
      await repo.hydrate([photo(etag: 'new')]);
      expect(repo.cached(photo(etag: 'new')), png);
      expect(repo.current(photo(etag: 'new')), isFalse);
    },
  );

  test('hydrate ignores files without a stored thumbnail', () async {
    final repo = repository();
    await repo.hydrate([photo(id: '7', etag: 'v1')]);
    expect(repo.cached(photo(id: '7', etag: 'v1')), isNull);
  });

  test('a cleared cache is not refilled by an in-flight hydrate', () async {
    final repo = repository();
    await cache.writeThumbnail(repo.key(photo(), 384)!, png, version: 'v1');
    final pending = repo.hydrate([photo(etag: 'v1')]);
    repo.clear();
    await pending;
    expect(repo.cached(photo(etag: 'v1')), isNull);
  });

  test('a saved original is replayed without any request', () async {
    final repo = repository();
    saved = File('${dir.path}/original.png')..writeAsBytesSync(png);
    final image = await repo.load(photo()).result;
    expect(image.original, saved);
    expect(image.bytes, isNull);
    expect(backend.requests, 0);
  });

  test('a failed download falls back to a saved original', () async {
    final repo = repository();
    saved = File('${dir.path}/original.png')..writeAsBytesSync(png);
    final image = await repo.load(photo(), retry: true).result;
    expect(image.original, saved);
    expect(backend.requests, 1);
  });

  test('a failed download keeps the thumbnail already shown', () async {
    final repo = repository();
    await cache.writeThumbnail(repo.key(photo(), 384)!, png, version: 'old');
    await repo.hydrate([photo(etag: 'new')]);
    saved = File('${dir.path}/original.png')..writeAsBytesSync(png);
    await expectLater(
      repo.load(photo(etag: 'new'), retry: true).result,
      throwsA(isA<CloudException>()),
    );
  });

  test('a failed download without an original reports the failure', () async {
    final repo = repository();
    await expectLater(
      repo.load(photo(), retry: true).result,
      throwsA(isA<CloudException>()),
    );
  });

  test(
    'an album cover of unknown revision reuses any stored thumbnail',
    () async {
      final repo = repository();
      const album = CloudAlbum(
        name: 'Trip',
        reference: ['Trip'],
        count: 1,
        coverId: '42',
      );
      final cover = album.cover!;
      await cache.writeThumbnail(repo.key(cover, 384)!, png, version: 'etag-1');
      final image = await repo.load(cover).result;
      expect(image.bytes, png);
      expect(backend.requests, 0);
      expect(repo.current(cover), isTrue);
      expect(repo.current(photo(etag: 'etag-2')), isFalse);
    },
  );

  test(
    'a versioned file still refreshes a thumbnail stored for another revision',
    () async {
      final repo = repository();
      await cache.writeThumbnail(
        repo.key(photo(), 384)!,
        png,
        version: 'etag-1',
      );
      await expectLater(
        repo.load(photo(etag: 'etag-2')).result,
        throwsA(isA<CloudException>()),
      );
      expect(backend.requests, 1);
    },
  );

  test(
    'shared album covers load in bounded parallel batches, sorted',
    () async {
      final shared = _Backend();
      final c = AppController(store: MemoryStore(), client: shared)
        ..account = account
        ..timelineIndexAvailable = false;
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.sharedAlbums.map((a) => a.name), [
        'a',
        'b',
        'c',
        'd',
        'e',
        'f',
        'g',
      ]);
      expect(shared.peak, 4);
    },
  );
}
