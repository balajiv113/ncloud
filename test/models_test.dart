import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/models.dart';

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
    expect(result.displayName, 'Example');
  });

  test('validates names and formats sizes', () {
    for (final name in ['', '..', '.', 'a/b', r'a\b', 'a\u0000b']) {
      expect(() => validateName(name), throwsFormatException);
    }
    validateName('Vacation & family #1');
    expect(formatBytes(1024), '1.0 KB');
    expect(formatBytes(1048576), '1.0 MB');
  });

  test('Smart albums stop at the first folder with media on each branch', () {
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
    expect(albums.map((a) => a.path), [
      ['Photos', 'Family', 'Kyoto'],
      ['Photos', 'Travel', 'Japan', 'Kyoto'],
    ]);
    expect(albums.last.files, hasLength(2));
    expect(albums.map((a) => a.key).toSet(), hasLength(2));
    expect(
      albums.any(
        (a) => [
          'Photos',
          'Travel',
          'Family',
          'Japan',
          'Temples',
          'Empty',
          'Docs',
        ].contains(a.name),
      ),
      isFalse,
    );
  });

  test(
    'loose source photos stay separate instead of collapsing all parent albums',
    () {
      CloudFile photo(List<String> path) => CloudFile(
        path: path,
        name: path.last,
        isDirectory: false,
        contentType: 'image/jpeg',
      );
      final files = [
        photo(['Photos', 'loose.jpg']),
        photo(['Photos', 'Travel', 'Japan', 'a.jpg']),
        photo(['Photos', 'Family', 'b.jpg']),
      ];
      final albums = buildSmartAlbums(files, ['Photos']);
      expect(albums.map((a) => a.name), ['Family', 'Japan', 'Photos']);
      expect(albums.expand((a) => a.files).toSet(), files.toSet());
      expect(albums.every((a) => a.files.length == 1), isTrue);
      expect(buildSmartAlbums(files, []).single.name, 'Photos');
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
      expect(updated.loginName, original.loginName);
      expect(updated.appPassword, original.appPassword);
      expect(Account.decode(original.encode()).photoRoot, isNull);
    },
  );
}
