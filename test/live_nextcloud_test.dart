import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ncloud/nextcloud_client.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/app_controller.dart';

import 'app_test.dart' show MemoryStore;

void main() {
  const enabled = bool.fromEnvironment('LIVE_NEXTCLOUD');
  test(
    'real Memories: indexed days, folders, capture metadata and batched DAV path resolution',
    () async {
      final client = NextcloudClient();
      addTearDown(client.close);
      final session = await client.authenticate(
        Uri.parse('http://127.0.0.1:8080'),
        'ncloud-ci',
        const String.fromEnvironment('NEXTCLOUD_TEST_PASSWORD'),
      );
      final folders = await client.memoryFolders(session, []);
      expect(
        folders.any(
          (f) => f.path.last == 'ncloud-index' && f.previews.isNotEmpty,
        ),
        isTrue,
      );
      final days = await client.memoryDays(
        session,
        path: ['ncloud-index'],
        recursive: false,
      );
      expect(days, isNotEmpty);
      expect(days!.fold<int>(0, (sum, day) => sum + day.count), 201);
      final allFiles = await client.listFiles(session, ['ncloud-index']);
      // Reproduce the server's operator-limit failure independently of paging.
      await expectLater(
        client.search(
          session,
          fileIds: allFiles.take(101).map((f) => f.id!).toList(),
        ),
        throwsA(isA<CloudException>()),
      );
      final files = await client.memoryDayFiles(
        session,
        days.map((d) => d.id).toList(),
        path: ['ncloud-index'],
        recursive: false,
      );
      expect(files, hasLength(201));
      final seed = files.singleWhere((f) => f.name == 'seed.png');
      expect(seed.path, ['ncloud-index', 'seed.png']);
      expect(seed.taken, isNotNull);
      expect(days.map((d) => d.id), contains(seed.captureDay));
      expect(seed.etag, isNotEmpty);
      expect(await client.preview(session, seed), isNotEmpty);
      final recursiveDays = await client.memoryDays(
        session,
        path: ['ncloud-index'],
      );
      expect(recursiveDays!.fold<int>(0, (sum, day) => sum + day.count), 202);
      expect(files.every((f) => f.path.length == 2), isTrue);
      final davDirect = await client.searchPage(
        session,
        path: ['ncloud-index'],
        recursive: false,
      );
      expect(davDirect.scanned, 200);
      expect(davDirect.files, isNotEmpty);
      expect(davDirect.files.every((f) => f.path.length == 2), isTrue);
      final controller = AppController(store: MemoryStore(), client: client)
        ..account = session.withPhotoRoot(['ncloud-index']);
      addTearDown(controller.dispose);
      await controller.selectTab(4);
      expect(controller.catalogueError, isNull);
      expect(controller.smartAlbums.map((a) => a.path), [
        ['ncloud-index'],
        ['ncloud-index', 'Travel', 'Japan'],
      ]);
      await controller.openSmartAlbum(['ncloud-index']);
      expect(controller.error, isNull);
      expect(controller.items, hasLength(201));
      expect(controller.items.every((f) => f.path.length == 2), isTrue);
      await controller.openSmartAlbum(['ncloud-index', 'Travel', 'Japan']);
      expect(controller.error, isNull);
      expect(controller.items.single.path, [
        'ncloud-index',
        'Travel',
        'Japan',
        'nested.png',
      ]);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'real incoming shared folders become albums without relying on recipient Memories indexing',
    () async {
      final client = NextcloudClient();
      addTearDown(client.close);
      final server = Uri.parse('http://127.0.0.1:8080');
      const password = String.fromEnvironment('NEXTCLOUD_TEST_PASSWORD');
      final owner = await client.authenticate(server, 'ncloud-ci', password);
      final receiverId =
          'ncloud-receiver-${DateTime.now().microsecondsSinceEpoch}';
      final transport = http.Client();
      addTearDown(transport.close);
      final headers = {
        'Authorization': owner.authorization,
        'OCS-APIRequest': 'true',
        'Accept': 'application/json',
      };
      final create = await transport.post(
        server.resolve('/ocs/v1.php/cloud/users?format=json'),
        headers: headers,
        body: {'userid': receiverId, 'password': password},
      );
      expect(create.statusCode, 200);
      expect((jsonDecode(create.body) as Map)['ocs']['meta']['status'], 'ok');
      addTearDown(() async {
        final response = await transport.delete(
          server.resolve('/ocs/v1.php/cloud/users/$receiverId?format=json'),
          headers: headers,
        );
        expect(response.statusCode, 200);
      });
      final share = await transport.post(
        server.resolve(
          '/ocs/v2.php/apps/files_sharing/api/v1/shares?format=json',
        ),
        headers: headers,
        body: {
          'path': '/ncloud-index',
          'shareType': '0',
          'shareWith': receiverId,
          'permissions': '1',
        },
      );
      expect(share.statusCode, 200);
      expect((jsonDecode(share.body) as Map)['ocs']['meta']['status'], 'ok');
      expect(await client.incomingSharedFolders(owner), isEmpty);
      final receiver = await client.authenticate(server, receiverId, password);
      final incoming = await client.incomingSharedFolders(receiver);
      expect(incoming, [
        ['ncloud-index'],
      ]);
      final controller = AppController(store: MemoryStore(), client: client)
        ..account = receiver
        ..memoriesAvailable = true;
      addTearDown(controller.dispose);
      await controller.selectTab(5);
      expect(controller.sharedAlbumError, isNull);
      expect(controller.sharedAlbums.single.path, ['ncloud-index']);
      await controller.openSharedAlbum(['ncloud-index']);
      expect(controller.error, isNull);
      expect(controller.items, hasLength(200));
      expect(controller.hasMore, isTrue);
      await controller.loadNextPage();
      expect(controller.error, isNull);
      expect(controller.items, hasLength(202));
      expect(controller.items.any((f) => f.path.last == 'nested.png'), isTrue);
      expect(controller.hasMore, isFalse);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 1)),
  );
  test(
    'real Nextcloud: profile, folders, upload, favorites, search, preview, download',
    () async {
      final client = NextcloudClient();
      addTearDown(client.close);
      // HTTP is restricted to this isolated CI fixture, never app sign-in.
      final server = Uri.parse('http://127.0.0.1:8080');
      final account = await client.authenticate(
        server,
        'ncloud-ci',
        const String.fromEnvironment('NEXTCLOUD_TEST_PASSWORD'),
      );
      final folder = ['ncloud smoke #${DateTime.now().microsecondsSinceEpoch}'];
      await client.createFolder(account, folder);
      addTearDown(() async {
        final cleanup = http.Client();
        try {
          final response = await cleanup.delete(
            client.davUri(account, folder),
            headers: {'Authorization': account.authorization},
          );
          expect(response.statusCode, 204);
        } finally {
          cleanup.close();
        }
      });

      final bytes = base64Decode(
        'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQqMgGAAGnAPzLMdOkAAAAAElFTkSuQmCC',
      );
      final path = [...folder, 'Photo & sunshine #1.png'];
      await client.upload(account, path, Stream.value(bytes), bytes.length);
      final files = await client.listFiles(account, folder);
      expect(files, hasLength(1));
      final photo = files.single;
      expect(photo.path, path);
      expect(photo.isImage, isTrue);
      expect(photo.size, bytes.length);
      expect(photo.id, isNotNull);
      expect(photo.modified, isNotNull);

      await expectLater(
        client.upload(account, path, Stream.value(bytes), bytes.length),
        throwsA(isA<CloudException>()),
      );
      await client.setFavorite(account, photo, true);
      final favorites = await client.search(account, favorites: true);
      expect(favorites.any((f) => f.key == photo.key), isTrue);
      final photos = await client.search(account);
      expect(photos.any((f) => f.key == photo.key), isTrue);
      final nativeName =
          'ncloud album ${DateTime.now().microsecondsSinceEpoch}';
      final nativeUri = serverEndpoint(server, [
        'remote.php',
        'dav',
        'photos',
        account.userId,
        'albums',
        nativeName,
      ]);
      final nativeTransport = http.Client();
      addTearDown(nativeTransport.close);
      final createAlbum = http.Request('MKCOL', nativeUri)
        ..headers['Authorization'] = account.authorization;
      final created = await nativeTransport.send(createAlbum);
      await created.stream.drain<void>();
      expect(created.statusCode, 201);
      addTearDown(() async {
        final cleanup = await nativeTransport.delete(
          nativeUri,
          headers: {'Authorization': account.authorization},
        );
        expect(cleanup.statusCode, 204);
      });
      final emptyNative = (await client.albums(
        account,
      )).singleWhere((a) => a.name == nativeName);
      expect(emptyNative.count, 0);
      final addMember = http.Request('COPY', client.davUri(account, photo.path))
        ..headers.addAll({
          'Authorization': account.authorization,
          'Destination': serverEndpoint(server, [
            'remote.php',
            'dav',
            ...emptyNative.davPath,
            photo.id!,
          ]).toString(),
          'Depth': '0',
        });
      final added = await nativeTransport.send(addMember);
      await added.stream.drain<void>();
      expect(added.statusCode, anyOf(201, 204));
      final nativeFiles = await client.albumFiles(account, emptyNative, photos);
      expect(nativeFiles, hasLength(1));
      expect(nativeFiles.single.key, photo.key);
      expect(await client.preview(account, photo), isNotEmpty);
      final download = await client.download(account, photo);
      expect(await download.stream.toBytes(), bytes);
      await client.setFavorite(account, photo, false);
      expect(
        (await client.listFiles(account, folder)).single.favorite,
        isFalse,
      );
      final page1 = await client.search(account, path: folder, limit: 1);
      expect(page1.single.key, photo.key);
      expect(
        await client.search(account, path: folder, offset: 1, limit: 1),
        isEmpty,
      );

      final renamedPath = [...folder, 'Renamed #photo.png'];
      await client.transfer(account, photo, renamedPath);
      final renamed = (await client.listFiles(account, folder)).single;
      expect(renamed.path, renamedPath);
      final album = [...folder, 'Album & family'];
      await client.createFolder(account, album);
      await client.transfer(account, renamed, [
        ...album,
        renamed.name,
      ], copy: true);
      final copied = (await client.listFiles(account, album)).single;
      expect(copied.name, renamed.name);
      final share = await client.createShare(
        account,
        copied,
        password: 'disposable-fixture-link',
        expires: DateTime.now().add(const Duration(days: 7)),
      );
      expect(share.url.path, contains('/s/'));
      expect(
        (await client.shares(account, copied)).any((s) => s.id == share.id),
        isTrue,
      );
      await client.revokeShare(account, share);
      expect(await client.shares(account, copied), isEmpty);
      await client.delete(account, copied);
      expect(await client.listFiles(account, album), isEmpty);
      final trashed = (await client.trash(account))
          .where(
            (e) =>
                e.originalPath.contains(folder.single) && e.name == copied.name,
          )
          .single;
      await client.restore(account, trashed);
      expect((await client.listFiles(account, album)).single.name, copied.name);
      await client.delete(
        account,
        (await client.listFiles(account, album)).single,
      );
      final conflictTrash = (await client.trash(account))
          .where(
            (e) =>
                e.originalPath.contains(folder.single) && e.name == copied.name,
          )
          .single;
      final replacement = utf8.encode('Existing content must survive restore');
      await client.upload(
        account,
        copied.path,
        Stream.value(replacement),
        replacement.length,
      );
      await client.restore(account, conflictTrash);
      final recovered = await client.listFiles(account, album);
      expect(recovered, hasLength(2));
      final existing = recovered.singleWhere((f) => f.name == copied.name);
      final restored = recovered.singleWhere((f) => f.name != copied.name);
      expect(
        await (await client.download(account, existing)).stream.toBytes(),
        replacement,
      );
      expect(
        await (await client.download(account, restored)).stream.toBytes(),
        bytes,
      );
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
