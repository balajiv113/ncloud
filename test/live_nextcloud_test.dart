import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ncloud/models.dart';
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
      expect((await client.listFiles(account, folder)).single.favorite, isFalse);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
