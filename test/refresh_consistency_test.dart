import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/cloud_backend.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/models.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account;

CloudFile _photo(String folder) => CloudFile(
  path: ['Photos', folder, 'cover.jpg'],
  name: 'cover.jpg',
  isDirectory: false,
  contentType: 'image/jpeg',
  id: folder,
  etag: folder,
);

class _Backend implements CloudBackend {
  String folder = 'Trip';
  bool fail = false;
  Completer<List<CloudFile>>? delayedRoot;
  Completer<List<List<String>>>? delayedShares;
  int rootCalls = 0;
  int shareCalls = 0;

  @override
  int get pageSize => 200;
  @override
  void close() {}

  List<CloudFile> root(String name) => [
    CloudFile(path: ['Photos', name], name: name, isDirectory: true),
  ];

  @override
  Future<({CloudFile? self, List<CloudFile> children})> listFolder(
    Account account,
    List<String> path,
  ) async {
    if (fail) throw const CloudException('Refresh failed');
    if (path.length == 1) {
      rootCalls++;
      if (delayedRoot case final pending?) {
        delayedRoot = null;
        return (self: null, children: await pending.future);
      }
      return (self: null, children: root(folder));
    }
    return (self: null, children: [_photo(path.last)]);
  }

  @override
  Future<List<CloudAlbum>> albums(
    Account account, {
    bool shared = false,
  }) async {
    if (fail) throw const CloudException('Refresh failed');
    return shared
        ? []
        : [
            CloudAlbum(name: folder, reference: [folder], count: 1),
          ];
  }

  @override
  Future<List<RecognizedPerson>?> people(
    Account account, {
    List<String> path = const [],
    bool optional = false,
  }) async => [];

  @override
  Future<List<List<String>>> incomingSharedFolders(Account account) async {
    shareCalls++;
    if (fail) throw const CloudException('Refresh failed');
    if (delayedShares case final pending?) {
      delayedShares = null;
      return pending.future;
    }
    return [
      ['Photos', folder],
    ];
  }

  @override
  Future<List<CloudFile>> search(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = 200,
    List<String>? fileIds,
    bool recursive = true,
  }) async => [_photo(path.last)];

  @override
  Future<({List<CloudFile> files, int scanned})> searchPage(
    Account account, {
    bool favorites = false,
    List<String> path = const [],
    int offset = 0,
    int limit = 200,
    List<String>? fileIds,
    bool recursive = true,
  }) async => (files: [_photo(path.last)], scanned: 1);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

AppController _controller(_Backend backend) =>
    AppController(store: MemoryStore(), client: backend)
      ..account = account.withPhotoRoot(['Photos'])
      ..timelineIndexAvailable = false;

Future<void> _flush() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'albums remain openable during authoritative fallback refresh',
    () async {
      final backend = _Backend();
      final c = _controller(backend);
      addTearDown(c.dispose);
      await c.selectTab(4);
      expect(c.smartAlbums.single.name, 'Trip');
      final gate = Completer<List<CloudFile>>();
      backend.delayedRoot = gate;
      backend.folder = 'Family';
      final refreshing = c.load();
      await _flush();
      expect(c.smartAlbums.single.name, 'Trip');
      expect(c.discoveringAlbums, isTrue);
      expect(
        backend.rootCalls,
        2,
        reason: 'forced refresh must bypass folder RAM cache',
      );
      await c.openSmartAlbum(['Photos', 'Trip']);
      expect(c.items.single.id, 'Trip');
      gate.complete(backend.root('Family'));
      await refreshing;
      expect(c.smartAlbums.single.name, 'Family');
      expect(c.nativeAlbums.single.name, 'Family');
      expect(
        c.items.single.id,
        'Trip',
        reason: 'refresh must not replace the opened view',
      );
      expect(c.directory, ['Photos', 'Trip']);
      expect(c.catalogueError, isNull);
    },
  );

  test(
    'failed refresh retains Smart, native and Shared albums with errors',
    () async {
      final backend = _Backend();
      final c = _controller(backend);
      addTearDown(c.dispose);
      await c.selectTab(4);
      backend.fail = true;
      await c.load();
      expect(c.smartAlbums.single.name, 'Trip');
      expect(c.nativeAlbums.single.name, 'Trip');
      expect(c.sharedAlbums.single.name, 'Trip');
      expect(c.catalogueError, contains('Refresh failed'));
      expect(c.sharedAlbumError, contains('Refresh failed'));
      expect(c.loading, isFalse);
    },
  );

  test(
    'a second forced refresh supersedes old Smart and Shared responses',
    () async {
      final backend = _Backend();
      final c = _controller(backend);
      addTearDown(c.dispose);
      await c.selectTab(4);
      final oldRoot = Completer<List<CloudFile>>();
      final oldShares = Completer<List<List<String>>>();
      backend.delayedRoot = oldRoot;
      backend.delayedShares = oldShares;
      final oldRefresh = c.load();
      await _flush();
      backend.folder = 'Family';
      await c.load();
      expect(c.smartAlbums.single.name, 'Family');
      expect(c.sharedAlbums.single.name, 'Family');
      oldRoot.complete(backend.root('Obsolete'));
      oldShares.complete([
        ['Photos', 'Obsolete'],
      ]);
      await oldRefresh;
      expect(c.smartAlbums.single.name, 'Family');
      expect(c.sharedAlbums.single.name, 'Family');
      expect(c.nativeAlbums.single.name, 'Family');
      expect(c.fileStore.folder(['Photos'])!.single.name, 'Family');
      expect(c.loadingSharedAlbums, isFalse);
    },
  );

  test(
    'Drive refresh keeps existing files and reconciles removed folders',
    () async {
      final backend = _Backend();
      final c = _controller(backend)..tab = 1;
      addTearDown(c.dispose);
      await c.goTo(['Photos']);
      expect(c.items.single.name, 'Trip');
      final gate = Completer<List<CloudFile>>();
      backend.delayedRoot = gate;
      final refresh = c.load();
      await _flush();
      expect(c.items.single.name, 'Trip');
      expect(c.refreshing, isTrue);
      gate.complete(backend.root('Family'));
      await refresh;
      expect(c.items.single.name, 'Family');
      expect(c.fileStore['Photos/Trip'], isNull);
      expect(c.refreshing, isFalse);
    },
  );
}
