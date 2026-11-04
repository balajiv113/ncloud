import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ncloud/nextcloud_client.dart';

void main() {
  const enabled = bool.fromEnvironment('LIVE_NEXTCLOUD');
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
      expect(await client.search(account, path: folder, offset: 1, limit: 1), isEmpty);

      final renamedPath = [...folder, 'Renamed #photo.png'];
      await client.transfer(account, photo, renamedPath);
      final renamed = (await client.listFiles(account, folder)).single;
      expect(renamed.path, renamedPath);
      final album = [...folder, 'Album & family'];
      await client.createFolder(account, album);
      await client.transfer(account, renamed, [...album, renamed.name], copy: true);
      final copied = (await client.listFiles(account, album)).single;
      expect(copied.name, renamed.name);
      final share = await client.createShare(account, copied,
        password: 'disposable-fixture-link', expires: DateTime.now().add(const Duration(days: 7)));
      expect(share.url.path, contains('/s/'));
      expect((await client.shares(account, copied)).any((s) => s.id == share.id), isTrue);
      await client.revokeShare(account, share);
      expect(await client.shares(account, copied), isEmpty);
      await client.delete(account, copied);
      expect(await client.listFiles(account, album), isEmpty);
      final trashed = (await client.trash(account)).where((e) => e.originalPath.contains(folder.single) && e.name == copied.name).single;
      await client.restore(account, trashed);
      expect((await client.listFiles(account, album)).single.name, copied.name);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
