import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/models.dart';

void main() {
  test('normalizes HTTPS subfolder installs without losing encoded paths', () {
    final server = normalizeServer(' https://example.com/nextcloud/ ');
    expect(server.toString(), 'https://example.com/nextcloud');
    final uri = serverEndpoint(server, [
      'remote.php',
      'dav',
      'files',
      'a@b',
      'a #?.jpg',
    ]);
    expect(uri.pathSegments.last, 'a #?.jpg');
    expect(uri.toString(), contains('a%20%23%3F.jpg'));
    expect(uri.pathSegments, contains('nextcloud'));
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

  test('round trips accounts with a separate login name and DAV id', () {
    final account = Account(
      server: normalizeServer('https://example.com'),
      loginName: 'user@example.com',
      appPassword: 'a:b',
      userId: 'internal-id',
      displayName: 'Example',
    );
    final result = Account.decode(account.encode());
    expect(result.userId, 'internal-id');
    expect(result.loginName, 'user@example.com');
    expect(result.appPassword, 'a:b');
    expect(result.authorization, startsWith('Basic '));
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
    'Smart albums skip empty and grouping folders and keep nested collections',
    () {
      CloudFile photo(List<String> path) => CloudFile(
        path: path,
        name: path.last,
        isDirectory: false,
        contentType: 'image/jpeg',
      );
      final files = [
        const CloudFile(
          path: ['Photos', 'Empty'],
          name: 'Empty',
          isDirectory: true,
        ),
        const CloudFile(
          path: ['Photos', 'Docs', 'notes.pdf'],
          name: 'notes.pdf',
          isDirectory: false,
          contentType: 'application/pdf',
        ),
        photo(['Photos', 'Travel', 'Japan', 'Kyoto', 'a.jpg']),
        photo(['Photos', 'Travel', 'Japan', 'Kyoto', 'Temples', 'b.jpg']),
        photo(['Photos', 'Family', 'Kyoto', 'c.jpg']),
        photo(['Other', 'Excluded', 'd.jpg']),
      ];
      final albums = buildSmartAlbums(files, ['Photos']);
      expect(albums.map((a) => a.name), ['Kyoto', 'Kyoto', 'Temples']);
      expect(
        albums.where((a) => a.path.contains('Japan')).first.files,
        hasLength(2),
      );
      expect(albums.map((a) => a.key).toSet(), hasLength(3));
      expect(
        albums.any(
          (a) =>
              ['Photos', 'Travel', 'Japan', 'Empty', 'Docs'].contains(a.name),
        ),
        isFalse,
      );
    },
  );

  test(
    'photo source survives account persistence without changing credentials',
    () {
      final original = Account(
        server: Uri.parse('https://cloud.example.com'),
        loginName: 'user',
        appPassword: 'app-password',
        userId: 'uid',
        displayName: 'User',
      );
      final updated = Account.decode(
        original.withPhotoRoot(['Photos', 'Family']).encode(),
      );
      expect(updated.photoRoot, ['Photos', 'Family']);
      expect(updated.authorization, original.authorization);
      expect(Account.decode(original.encode()).photoRoot, isNull);
    },
  );
}
