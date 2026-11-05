import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ncloud/nextcloud_client.dart';
import 'package:ncloud/models.dart';

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
      final files = await client.memoryDayFiles(
        session,
        [days!.first.id],
        path: ['ncloud-index'],
      );
      final seed = files.singleWhere((f) => f.name == 'seed.png');
      expect(seed.path, ['ncloud-index', 'seed.png']);
      expect(seed.taken, isNotNull);
      expect(seed.captureDay, days.first.id);
      expect(seed.etag, isNotEmpty);
      expect(await client.preview(session, seed), isNotEmpty);
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
