import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/models.dart';

void main() {
  test('normalizes HTTPS subfolder installs without losing encoded paths', () {
    final server = normalizeServer(' https://example.com/nextcloud/ ');
    expect(server.toString(), 'https://example.com/nextcloud');
    final uri = serverEndpoint(server, ['remote.php', 'dav', 'files', 'a@b', 'a #?.jpg']);
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
}
