import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/library/change_monitor.dart';
import 'package:ncloud/features/library/file_resolver.dart';
import 'package:ncloud/features/library/media_listing.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/models.dart';

class _SessionStore implements SessionStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> clear() async {}
}

class _PortableAccount extends Account {
  const _PortableAccount(this.storageKey, {this.photoRoot});
  @override
  final String storageKey;
  @override
  final List<String>? photoRoot;
  @override
  String get displayName => 'Portable user';
  @override
  String get serverLabel => 'Portable storage';
  @override
  String encode() => storageKey;
  @override
  _PortableAccount withPhotoRoot(List<String> path) =>
      _PortableAccount(storageKey, photoRoot: List.unmodifiable(path));
}

class _PortableBackend implements CloudBackend {
  final hints = StreamController<Set<String>?>.broadcast();
  final requestedLimits = <int>[];
  bool closed = false;
  int resolutionCalls = 0;
  int folderListings = 0;
  int folderInspections = 0;
  final resolution = Completer<Map<String, CloudFile>>();
  final batches = <Completer<List<Uint8List?>>>[];
  Completer<TimelineResult>? delayedPage;
  final pageRequested = Completer<void>();

  @override
  Future<FolderListing> listFolder(
    Account account,
    List<String> path, {
    bool metadataOnly = false,
    bool optional = false,
  }) async {
    if (metadataOnly) {
      folderInspections++;
      return const FolderListing(revision: 'opaque:folder-revision');
    }
    folderListings++;
    return FolderListing(
      revision: 'opaque:folder-revision',
      children: [
        CloudFile(
          path: [...path, 'photo.jpg'],
          name: 'photo.jpg',
          isDirectory: false,
        ),
      ],
    );
  }

  @override
  Future<List<Uint8List?>> previews(
    Account account,
    List<CloudFile> files, {
    int size = 384,
  }) {
    if (files.length == 1) {
      return Future.value([
        Uint8List.fromList([1, 2, 3]),
      ]);
    }
    final response = Completer<List<Uint8List?>>();
    batches.add(response);
    return response.future;
  }

  @override
  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids,
  ) {
    resolutionCalls++;
    return resolution.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected operation: ${invocation.memberName}');

  @override
  void close() {
    closed = true;
    unawaited(hints.close());
  }

  @override
  Stream<Set<String>?> changes(Account account) => hints.stream;

  @override
  PlaybackSource playbackSource(Account account, CloudFile file) => (
    uri: Uri.parse('https://media.example/video/${file.id}'),
    headers: {'Authorization': 'Bearer media-token'},
  );

  @override
  Future<TimelineResult?> timeline(Account account, TimelineQuery query) async {
    if (!query.paged) throw StateError('Expected a page request.');
    requestedLimits.add(query.limit);
    if (delayedPage case final pending?) {
      if (!pageRequested.isCompleted) pageRequested.complete();
      return pending.future;
    }
    final files = [
      for (var i = 0; i < 3; i++)
        CloudFile(
          path: ['Pictures', 'item-$i.jpg'],
          name: 'item-$i.jpg',
          isDirectory: false,
          contentType: 'image/jpeg',
          id: 'opaque:$i',
        ),
    ];
    if (query.cursor == null) {
      return TimelineResult.page(files.take(2).toList(), 'opaque:next');
    }
    if (query.cursor != 'opaque:next') throw StateError('Unexpected cursor.');
    return TimelineResult.page(files.skip(2).toList(), null);
  }
}

class _QueuedResolutionBackend extends _PortableBackend {
  final requests = <Completer<Map<String, CloudFile>>>[];

  @override
  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids,
  ) {
    resolutionCalls++;
    final request = Completer<Map<String, CloudFile>>();
    requests.add(request);
    return request.future;
  }

  @override
  Future<void> move(
    Account account,
    CloudFile file,
    List<String> destination,
  ) async {}
}

class _ShareBackend extends _PortableBackend {
  final pendingShares = Completer<List<PublicShare>>();
  int listCalls = 0;
  int createCalls = 0;
  int revokeCalls = 0;
  Account? requestedAccount;

  @override
  Future<List<PublicShare>> shares(Account account, CloudFile file) {
    requestedAccount = account;
    listCalls++;
    return pendingShares.future;
  }

  @override
  Future<PublicShare> createShare(
    Account account,
    CloudFile file, {
    String? password,
    DateTime? expires,
  }) async {
    requestedAccount = account;
    createCalls++;
    return PublicShare(id: '1', url: Uri.parse('https://example.test/share'));
  }

  @override
  Future<void> revokeShare(Account account, PublicShare share) async {
    requestedAccount = account;
    revokeCalls++;
  }
}

class _MapBackend extends _PortableBackend {
  final requests = <Completer<List<PhotoMapCluster>>>[];

  @override
  Future<List<PhotoMapCluster>> mapClusters(
    Account account, {
    required PhotoMapBounds bounds,
    required int zoom,
    List<String> path = const [],
  }) {
    final request = Completer<List<PhotoMapCluster>>();
    requests.add(request);
    return request.future;
  }
}

void main() {
  const account = _PortableAccount('portable|account');

  test(
    'map session merges wrapped clusters and stops superseded requests',
    () async {
      final backend = _MapBackend();
      final controller = AppController(store: _SessionStore(), client: backend)
        ..account = account;
      addTearDown(controller.dispose);
      final bounds = PhotoMapBounds.viewport(
        south: -10,
        north: 10,
        west: 170,
        east: 190,
      );
      final cluster = PhotoMapCluster(
        id: 1,
        location: PhotoLocation(0, 175),
        count: 2,
      );
      var current = true;
      final session = controller.photoMapSession();
      final loading = session.clusters(
        bounds,
        zoom: 5,
        isCurrentViewport: () => current,
      );
      backend.requests.first.complete([cluster]);
      await Future<void>.delayed(Duration.zero);
      expect(backend.requests, hasLength(2));
      backend.requests.last.complete([cluster]);
      expect((await loading)!.map((c) => c.id), [1]);

      final stale = session.clusters(
        bounds,
        zoom: 5,
        isCurrentViewport: () => current,
      );
      current = false;
      backend.requests.last.complete([cluster]);
      expect(await stale, isNull);
      expect(backend.requests, hasLength(3));

      current = true;
      final oldAccount = session.clusters(
        bounds,
        zoom: 5,
        isCurrentViewport: () => current,
      );
      final failed = expectLater(oldAccount, throwsA(isA<CloudException>()));
      controller.account = const _PortableAccount('portable|other');
      backend.requests.last.complete([cluster]);
      await failed;
      expect(backend.requests, hasLength(4));
    },
  );

  test(
    'share panel operations are bound to their initiating account',
    () async {
      final backend = _ShareBackend();
      final controller = AppController(store: _SessionStore(), client: backend)
        ..account = account;
      addTearDown(controller.dispose);
      const file = CloudFile(
        path: ['photo.jpg'],
        name: 'photo.jpg',
        isDirectory: false,
      );
      final session = controller.shareSession(file);
      final created = await session.create(password: 'password');
      expect(backend.requestedAccount, same(account));
      await session.revoke(created);
      final pending = session.list();
      final failed = expectLater(pending, throwsA(isA<CloudException>()));
      controller.account = const _PortableAccount('portable|other');
      backend.pendingShares.complete([created]);
      await failed;
      await expectLater(session.create(), throwsA(isA<CloudException>()));
      await expectLater(
        session.revoke(created),
        throwsA(isA<CloudException>()),
      );
      expect(backend.createCalls, 1);
      expect(backend.revokeCalls, 1);
      expect(backend.listCalls, 1);
    },
  );

  test('listing persists opaque continuation tokens unchanged', () {
    final listing = MediaListing()
      ..cursor = 'provider:continuation/opaque=='
      ..more = true;
    final restored = MediaListing.fromJson(listing.toJson());
    expect(restored.cursor, 'provider:continuation/opaque==');
    expect(restored.more, isTrue);
  });

  test('moving a file invalidates its cached lazy location', () async {
    final backend = _QueuedResolutionBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account
      ..tab = 1;
    addTearDown(controller.dispose);
    const file = CloudFile(
      path: [CloudFile.pendingRoot, 'opaque:1'],
      name: 'photo.jpg',
      isDirectory: false,
      id: 'opaque:1',
    );
    final first = controller.resolve(file);
    backend.requests.first.complete({
      'opaque:1': file.atPath(['Old', 'photo.jpg']),
    });
    final resolved = await first;
    expect(
      await controller.organize([resolved], 'move', destination: ['New']),
      isTrue,
    );
    final refreshed = controller.resolve(file);
    expect(backend.resolutionCalls, 2);
    backend.requests.last.complete({
      'opaque:1': file.atPath(['New', 'photo.jpg']),
    });
    expect((await refreshed).path, ['New', 'photo.jpg']);
  });

  test(
    'folder cache uses provider revision independent of file metadata',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'ncloud-provider-folder-',
      );
      final cache = LocalCache(() async => root);
      final backend = _PortableBackend();
      final controller = AppController(
        store: _SessionStore(),
        client: backend,
        cache: cache,
      )..account = account;
      try {
        expect(await controller.folderContents(['Photos']), hasLength(1));
        await cache.writeLibrary(
          'library-v1|${account.storageKey}',
          controller.fileStore,
        );
        controller.fileStore.markStale();
        expect(await controller.folderContents(['Photos']), hasLength(1));
        expect(backend.folderListings, 1);
        expect(backend.folderInspections, 1);
      } finally {
        controller.dispose();
        await cache.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('late initial page cannot populate a replacement account', () async {
    final backend = _PortableBackend()..delayedPage = Completer();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account
      ..timelineIndexAvailable = false;
    controller.setBrowsingActive(false);
    addTearDown(controller.dispose);
    final pending = controller.load();
    await backend.pageRequested.future;
    controller.account = const _PortableAccount('portable|other');
    backend.delayedPage!.complete(
      const TimelineResult.page([
        CloudFile(
          path: ['Pictures', 'private.jpg'],
          name: 'private.jpg',
          isDirectory: false,
          id: 'private',
        ),
      ], null),
    );
    await pending;
    expect(controller.fileStore.length, 0);
    expect(controller.items, isEmpty);
  });

  test('late initial page cannot overwrite a newer destination', () async {
    final backend = _PortableBackend()..delayedPage = Completer();
    final delayed = backend.delayedPage!;
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account
      ..timelineIndexAvailable = false;
    controller.setBrowsingActive(false);
    addTearDown(controller.dispose);
    final pending = controller.load();
    await backend.pageRequested.future;
    backend.delayedPage = null;
    await controller.selectTab(2);
    final keys = controller.fileStore
        .where((_) => true)
        .map((file) => file.key)
        .toSet();
    delayed.complete(
      const TimelineResult.page([
        CloudFile(
          path: ['Pictures', 'stale.jpg'],
          name: 'stale.jpg',
          isDirectory: false,
        ),
      ], null),
    );
    await pending;
    expect(
      controller.fileStore.where((_) => true).map((file) => file.key).toSet(),
      keys,
    );
    expect(controller.items.any((file) => file.name == 'stale.jpg'), isFalse);
  });

  testWidgets('old preview batches cannot strand a new session queue', (
    tester,
  ) async {
    final backend = _PortableBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account
      ..timelineIndexAvailable = true;
    addTearDown(controller.dispose);
    CloudFile photo(int id) => CloudFile(
      path: ['Pictures', '$id.jpg'],
      name: '$id.jpg',
      isDirectory: false,
      contentType: 'image/jpeg',
      id: '$id',
    );
    final cancelled = <Future<void>>[];
    for (var batch = 0; batch < 3; batch++) {
      for (var index = 0; index < 2; index++) {
        cancelled.add(
          expectLater(
            controller.preview(photo(batch * 2 + index)),
            throwsA(isA<PreviewCancelled>()),
          ),
        );
      }
      await tester.pump(const Duration(milliseconds: 12));
    }
    expect(backend.batches, hasLength(3));
    controller.account = account.withPhotoRoot(['Pictures']);
    final next = [controller.preview(photo(10)), controller.preview(photo(11))];
    await tester.pump(const Duration(milliseconds: 12));
    expect(backend.batches, hasLength(3));
    backend.batches.first.complete([null, null]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(backend.batches, hasLength(4));
    for (final batch in backend.batches.skip(1)) {
      batch.complete([null, null]);
    }
    await tester.pump();
    await Future.wait(cancelled);
    expect(await Future.wait(next), [
      [1, 2, 3],
      [1, 2, 3],
    ]);
  });

  testWidgets('disposing cancels previews still queued for batching', (
    tester,
  ) async {
    final backend = _PortableBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account
      ..timelineIndexAvailable = true;
    const file = CloudFile(
      path: ['Pictures', 'one.jpg'],
      name: 'one.jpg',
      isDirectory: false,
      contentType: 'image/jpeg',
      id: 'opaque:one',
    );
    final cancelled = expectLater(
      controller.preview(file),
      throwsA(isA<PreviewCancelled>()),
    );
    controller.dispose();
    await cancelled;
    await tester.pump(const Duration(milliseconds: 20));
    expect(backend.batches, isEmpty);
  });

  testWidgets('queued previews cannot cross account changes', (tester) async {
    final backend = _PortableBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account
      ..timelineIndexAvailable = true;
    addTearDown(controller.dispose);
    const file = CloudFile(
      path: ['Pictures', 'one.jpg'],
      name: 'one.jpg',
      isDirectory: false,
      contentType: 'image/jpeg',
      id: 'opaque:one',
    );
    final cancelled = expectLater(
      controller.preview(file),
      throwsA(isA<PreviewCancelled>()),
    );
    controller.account = const _PortableAccount('portable|other');
    final current = controller.preview(file);
    await tester.pump(const Duration(milliseconds: 12));
    await cancelled;
    expect(await current, [1, 2, 3]);
    expect(backend.batches, isEmpty);
  });

  test(
    'file resolution cannot populate another session with stale paths',
    () async {
      final backend = _PortableBackend();
      final controller = AppController(store: _SessionStore(), client: backend)
        ..account = account;
      addTearDown(controller.dispose);
      const file = CloudFile(
        path: [CloudFile.pendingRoot, 'opaque:1'],
        name: 'photo.jpg',
        isDirectory: false,
        id: 'opaque:1',
      );

      final pending = controller.resolve(file);
      final failed = expectLater(pending, throwsA(isA<CloudException>()));
      controller.account = null;
      backend.resolution.complete({
        'opaque:1': file.atPath(['Pictures', 'photo.jpg']),
      });
      await failed;
      expect(controller.fileStore.length, 0);
    },
  );

  test('resolved file locations are not reused across accounts', () async {
    final backend = _PortableBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account;
    addTearDown(controller.dispose);
    const file = CloudFile(
      path: [CloudFile.pendingRoot, 'opaque:1'],
      name: 'photo.jpg',
      isDirectory: false,
      id: 'opaque:1',
    );
    backend.resolution.complete({
      'opaque:1': file.atPath(['Pictures', 'photo.jpg']),
    });
    await controller.resolve(file);
    controller.account = const _PortableAccount('portable|other');
    await controller.resolve(file);
    expect(backend.resolutionCalls, 2);
  });

  test('concurrent resolution shares one provider request', () async {
    final backend = _PortableBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account;
    addTearDown(controller.dispose);
    const file = CloudFile(
      path: [CloudFile.pendingRoot, 'opaque:1'],
      name: 'photo.jpg',
      isDirectory: false,
      id: 'opaque:1',
    );
    final first = controller.resolve(file);
    final second = controller.resolve(file);
    expect(backend.resolutionCalls, 1);
    backend.resolution.complete({
      'opaque:1': file.atPath(['Pictures', 'photo.jpg']),
    });
    expect((await first).path, ['Pictures', 'photo.jpg']);
    expect((await second).path, ['Pictures', 'photo.jpg']);
  });

  test(
    'resolution cannot refill a cache cleared during reconciliation',
    () async {
      final backend = _PortableBackend();
      addTearDown(backend.close);
      const file = CloudFile(
        path: [CloudFile.pendingRoot, 'opaque:1'],
        name: 'photo.jpg',
        isDirectory: false,
        id: 'opaque:1',
      );
      late final FileResolver resolver;
      resolver = FileResolver(
        client: backend,
        account: () => account,
        active: () => true,
        apply: (id, result) {
          resolver.clear();
          return result;
        },
      );
      final pending = resolver.resolve(file);
      final failed = expectLater(pending, throwsA(isA<CloudException>()));
      backend.resolution.complete({
        'opaque:1': file.atPath(['Pictures', 'photo.jpg']),
      });
      await failed;
      expect(resolver.cached(file), isNull);
    },
  );

  test(
    'an old resolution cannot displace a new request after clearing',
    () async {
      final backend = _QueuedResolutionBackend();
      addTearDown(backend.close);
      const file = CloudFile(
        path: [CloudFile.pendingRoot, 'opaque:1'],
        name: 'photo.jpg',
        isDirectory: false,
        id: 'opaque:1',
      );
      final resolver = FileResolver(
        client: backend,
        account: () => account,
        active: () => true,
        apply: (id, result) => result,
      );
      final old = resolver.resolve(file);
      final oldFailure = expectLater(old, throwsA(isA<CloudException>()));
      resolver.clear();
      final current = resolver.resolve(file);
      backend.requests.first.complete({
        'opaque:1': file.atPath(['Old', 'photo.jpg']),
      });
      await oldFailure;
      final joined = resolver.resolve(file);
      expect(backend.resolutionCalls, 2);
      backend.requests.last.complete({
        'opaque:1': file.atPath(['New', 'photo.jpg']),
      });
      expect((await current).path, ['New', 'photo.jpg']);
      expect((await joined).path, ['New', 'photo.jpg']);
    },
  );

  test('file resolution cannot refill an explicitly cleared cache', () async {
    final backend = _PortableBackend();
    final controller = AppController(store: _SessionStore(), client: backend)
      ..account = account;
    addTearDown(controller.dispose);
    const file = CloudFile(
      path: [CloudFile.pendingRoot, 'opaque:1'],
      name: 'photo.jpg',
      isDirectory: false,
      id: 'opaque:1',
    );
    final pending = controller.resolve(file);
    final failed = expectLater(pending, throwsA(isA<CloudException>()));
    await controller.clearCache();
    backend.resolution.complete({
      'opaque:1': file.atPath(['Pictures', 'photo.jpg']),
    });
    await failed;
    expect(controller.fileStore.length, 0);
  });

  test(
    'controller pages, previews and streams through a different backend',
    () async {
      final backend = _PortableBackend();
      final controller = AppController(store: _SessionStore(), client: backend)
        ..account = account
        ..timelineIndexAvailable = false;
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.error, isNull);
      expect(controller.items, hasLength(2));
      expect(controller.hasMore, isTrue);
      await controller.loadNextPage();
      expect(controller.items, hasLength(3));
      expect(controller.hasMore, isFalse);
      expect(backend.requestedLimits, [200, 200]);
      final source = controller.playbackSource(controller.items.first)!;
      expect(source.uri.host, 'media.example');
      expect(source.headers, {'Authorization': 'Bearer media-token'});
      expect(await controller.preview(controller.items.first, size: 64), [
        1,
        2,
        3,
      ]);
    },
  );

  testWidgets(
    'change monitoring accepts opaque backend hints and cancels them',
    (tester) async {
      final backend = _PortableBackend();
      final checks = <({Set<String>? ids, bool pushed})>[];
      final monitor = ChangeMonitor(
        client: backend,
        account: account,
        check: (ids, pushed) async {
          checks.add((ids: ids, pushed: pushed));
          return false;
        },
        onActive: (_) {},
        onError: (error) => fail('$error'),
      );
      addTearDown(() {
        monitor.dispose();
        backend.close();
      });
      monitor.activity();
      await tester.pump();
      expect(backend.hints.hasListener, isTrue);
      backend.hints.add({'opaque:file-A', 'opaque:file-B'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(checks.last.ids, {'opaque:file-A', 'opaque:file-B'});
      expect(checks.last.pushed, isTrue);
      backend.hints.add({for (var i = 0; i < 300; i++) 'first:$i'});
      backend.hints.add({for (var i = 0; i < 300; i++) 'second:$i'});
      await tester.pump();
      await tester.pump(const Duration(seconds: 2));
      expect(checks.last.ids, isNull);
      expect(checks.last.pushed, isTrue);
      monitor.setForeground(false);
      await tester.pump();
      expect(backend.hints.hasListener, isFalse);
    },
  );
}
