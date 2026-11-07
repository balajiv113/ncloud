import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/change_monitor.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/models.dart';

class _SessionStore implements SessionStore {
  @override
  Future<String?> read() async => null;
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> clear() async {}
}

class _PortableBackend implements CloudBackend {
  final hints = StreamController<Set<String>?>.broadcast();
  final requestedLimits = <int>[];
  bool closed = false;
  final resolution = Completer<Map<String, CloudFile>>();
  final batches = <Completer<Map<String, Uint8List>>>[];
  Completer<({List<CloudFile> files, int scanned})>? delayedPage;
  final pageRequested = Completer<void>();

  @override
  Future<Map<String, Uint8List>> multipreview(
    Account account,
    List<String> fileIds, {
    int size = 384,
  }) {
    final response = Completer<Map<String, Uint8List>>();
    batches.add(response);
    return response.future;
  }

  @override
  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids, {
    int concurrency = 4,
  }) => resolution.future;

  @override
  int get pageSize => 2;

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
  MediaSource streamSource(Account account, CloudFile file) => (
    uri: Uri.parse('https://media.example/video/${file.id}'),
    headers: {'Authorization': 'Bearer media-token'},
  );

  @override
  Future<Uint8List> preview(
    Account account,
    CloudFile file, {
    int size = 384,
  }) async => Uint8List.fromList([1, 2, 3]);

  @override
  Future<({List<CloudFile> files, int scanned})> searchPage(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = 200,
    List<String>? fileIds,
    bool recursive = true,
  }) async {
    requestedLimits.add(limit);
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
    ].skip(offset).take(limit).toList();
    return (files: files, scanned: files.length);
  }
}

void main() {
  final account = Account(
    server: Uri.parse('https://storage.example'),
    loginName: 'portable-user',
    appPassword: 'opaque-credential',
    userId: 'user:opaque',
    displayName: 'Portable user',
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
    controller.account = Account(
      server: account.server,
      loginName: 'another-user',
      appPassword: 'another-password',
      userId: 'another-user',
      displayName: 'Another user',
    );
    backend.delayedPage!.complete((
      files: [
        const CloudFile(
          path: ['Pictures', 'private.jpg'],
          name: 'private.jpg',
          isDirectory: false,
          id: 'private',
        ),
      ],
      scanned: 1,
    ));
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
    delayed.complete((
      files: [
        const CloudFile(
          path: ['Pictures', 'stale.jpg'],
          name: 'stale.jpg',
          isDirectory: false,
        ),
      ],
      scanned: 1,
    ));
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
    backend.batches.first.complete({});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(backend.batches, hasLength(4));
    for (final batch in backend.batches.skip(1)) {
      batch.complete({});
    }
    await tester.pump();
    await Future.wait(cancelled);
    expect(await Future.wait(next), [
      [1, 2, 3],
      [1, 2, 3],
    ]);
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
      expect(backend.requestedLimits, [2, 2]);
      final source = controller.streamSource(controller.items.first)!;
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
