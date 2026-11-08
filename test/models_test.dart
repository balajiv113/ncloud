import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_account.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

void main() {
  test(
    'cloud album references and timeline days use neutral cache records',
    () {
      const file = CloudFile(
        path: ['Albums', 'cover'],
        name: 'cover.jpg',
        isDirectory: false,
        contentType: 'image/jpeg',
        albumReference: ['collection-token', 'member-token'],
      );
      final copy = CloudFile.fromJson(file.toJson());
      expect(copy.albumReference, file.albumReference);
      expect(
        copy.atPath(['Renamed', 'cover.jpg']).albumReference,
        file.albumReference,
      );
      expect(copy.readOnly, isTrue);
      expect(copy.toJson(), isNot(contains('albumDavPath')));
      const day = TimelineDay(21000, 12);
      expect(day.toJson(), {'id': 21000, 'count': 12});
      expect(TimelineDay.fromJson(day.toJson()).count, 12);
      expect(
        () => CloudFile.fromJson(file.toJson()..remove('favorite')),
        throwsA(isA<TypeError>()),
      );
    },
  );

  test('normalizes HTTPS subfolder installs', () {
    final server = normalizeServer(' https://example.com/nextcloud/ ');
    expect(server.toString(), 'https://example.com/nextcloud');
  });

  test('rejects unsafe server URLs', () {
    for (final url in [
      'http://example.com',
      'example.com',
      'https://user:pass@example.com',
      'https://example.com?token=secret',
      'https://example.com/#fragment',
      'https://example.com/../private',
      'https://example.com/%2e%2e/private',
    ]) {
      expect(() => normalizeServer(url), throwsFormatException, reason: url);
    }
  });

  test('round trips accounts with a separate login name and account id', () {
    final account = NextcloudAccount(
      server: normalizeServer('https://example.com'),
      loginName: 'user@example.com',
      appPassword: 'a:b',
      userId: 'internal-id',
      displayName: 'Example',
    );
    final client = NextcloudClient();
    addTearDown(client.close);
    final result = client.restoreAccount(account.encode());
    expect(result.userId, 'internal-id');
    expect(result.loginName, 'user@example.com');
    expect(result.appPassword, 'a:b');
    expect(result.displayName, 'Example');
    expect(result.storageKey, 'https://example.com|internal-id');
    expect(result.withPhotoRoot(['Photos']).storageKey, result.storageKey);
    expect(result.sameOwner(account), isTrue);
  });

  test('validates names and formats sizes', () {
    for (final name in ['', '..', '.', 'a/b', r'a\b', 'a\u0000b']) {
      expect(() => validateName(name), throwsFormatException);
    }
    validateName('Vacation & family #1');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1048576), '1.0 MB');
  });

  test(
    'photo source survives account persistence without changing credentials',
    () {
      final original = NextcloudAccount(
        server: Uri.parse('https://cloud.example.com'),
        loginName: 'user',
        appPassword: 'app-password',
        userId: 'uid',
        displayName: 'User',
      );
      final client = NextcloudClient();
      addTearDown(client.close);
      final updated = client.restoreAccount(
        original.withPhotoRoot(['Photos', 'Family']).encode(),
      );
      expect(updated.photoRoot, ['Photos', 'Family']);
      expect(updated.loginName, original.loginName);
      expect(updated.appPassword, original.appPassword);
      expect(client.restoreAccount(original.encode()).photoRoot, isNull);
    },
  );

  test('a native album cover is an id-only file, absent without a cover', () {
    const album = CloudAlbum(
      name: 'Trip',
      reference: ['photos', 'Trip'],
      count: 2,
      coverId: '43',
    );
    expect(album.cover?.id, '43');
    expect(album.cover?.etag, isNull);
    expect(album.cover?.modified, isNull);
    expect(
      const CloudAlbum(name: 'Empty', reference: ['Empty'], count: 0).cover,
      isNull,
    );
  });
}
