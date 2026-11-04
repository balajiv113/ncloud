import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';

final account = Account(
  server: normalizeServer('https://cloud.example/nextcloud'),
  loginName: 'email@example.com',
  appPassword: 'test-app-password',
  userId: 'alice',
  displayName: 'Alice',
);

String responseEntry({
  String href =
      '/nextcloud/remote.php/dav/files/alice/Photos/Beach%20%26%20sun.jpg',
  String name = 'Beach &amp; sun.jpg',
  String status = 'HTTP/1.1 200 OK',
  String properties = '',
}) =>
    '''
  <d:response><d:href>$href</d:href>
    <d:propstat><d:prop>
      <d:displayname>$name</d:displayname>
      <d:resourcetype/>
      <d:getcontenttype>image/jpeg</d:getcontenttype>
      <d:getcontentlength>2048</d:getcontentlength>
      <d:getlastmodified>Wed, 04 Nov 2026 10:11:12 GMT</d:getlastmodified>
      <oc:fileid>42</oc:fileid><oc:favorite>1</oc:favorite>
      $properties
    </d:prop><d:status>$status</d:status></d:propstat>
  </d:response>
''';

String multistatus(String body) =>
    '<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">$body</d:multistatus>';

void main() {
  test(
    'parses namespace-qualified properties, dates, and encoded filenames',
    () {
      final files = NextcloudClient.parseFiles(
        multistatus(responseEntry()),
        account,
      );
      expect(files, hasLength(1));
      final file = files.single;
      expect(file.name, 'Beach & sun.jpg');
      expect(file.path, ['Photos', 'Beach & sun.jpg']);
      expect(file.favorite, isTrue);
      expect(file.id, '42');
      expect(file.modified, DateTime.utc(2026, 11, 4, 10, 11, 12));
      expect(file.size, 2048);
    },
  );

  test('ignores failed properties and hrefs outside the account root', () {
    final xml = multistatus(
      [
        responseEntry(status: 'HTTP/1.1 404 Not Found'),
        responseEntry(href: '/nextcloud/remote.php/dav/files/bob/private.jpg'),
        responseEntry(
          href:
              'https://evil.example/nextcloud/remote.php/dav/files/alice/private.jpg',
        ),
        responseEntry(
          href: '/nextcloud/remote.php/dav/files/alice/Photos/a%2Fb.jpg',
        ),
        responseEntry(),
      ].join(),
    );
    expect(NextcloudClient.parseFiles(xml, account), hasLength(1));
  });

  test('resolves DAV user ID from OCS rather than login email', () async {
    final client = NextcloudClient(
      transport: MockClient((request) async {
        expect(request.url.path, '/nextcloud/ocs/v2.php/cloud/user');
        expect(request.headers['OCS-APIRequest'], 'true');
        return http.Response(
          jsonEncode({
            'ocs': {
              'meta': {'status': 'ok'},
              'data': {'id': 'alice', 'display-name': 'Alice'},
            },
          }),
          200,
        );
      }),
    );
    addTearDown(client.close);
    final result = await client.authenticate(
      account.server,
      account.loginName,
      account.appPassword,
    );
    expect(result.userId, 'alice');
    expect(client.davUri(result, ['a #?.txt']).pathSegments.last, 'a #?.txt');
  });

  test(
    'requests depth-one folder listing and drops the collection itself',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.method, 'PROPFIND');
          expect(request.headers['Depth'], '1');
          expect(request.headers['Authorization'], account.authorization);
          expect(request.followRedirects, isFalse);
          return http.Response(
            multistatus(
              responseEntry(
                    href: '/nextcloud/remote.php/dav/files/alice/Photos/',
                  ) +
                  responseEntry(),
            ),
            207,
          );
        }),
      );
      addTearDown(client.close);
      expect(await client.listFiles(account, ['Photos']), hasLength(1));
    },
  );

  test('search is recursive, server-scoped and bounded', () async {
    final client = NextcloudClient(
      transport: MockClient((request) async {
        expect(request.method, 'SEARCH');
        expect(request.url.path, '/nextcloud/remote.php/dav/');
        expect(request.body, contains('<d:depth>infinity</d:depth>'));
        expect(request.body, contains('<d:nresults>200</d:nresults>'));
        expect(request.body, contains('<d:href>/files/alice</d:href>'));
        return http.Response(multistatus(responseEntry()), 207);
      }),
    );
    addTearDown(client.close);
    expect(await client.search(account), hasLength(1));
  });

  test('login flow preserves a poll token and treats 404 as pending', () async {
    var calls = 0;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        calls++;
        expect(request.headers.containsKey('Authorization'), isFalse);
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'login': 'https://cloud.example/nextcloud/login/v2/flow/abc',
              'poll': {
                'token': 'a+b&c',
                'endpoint': 'https://cloud.example/nextcloud/login/v2/poll',
              },
            }),
            200,
          );
        }
        expect(Uri.splitQueryString(request.body)['token'], 'a+b&c');
        return http.Response('', 404);
      }),
    );
    addTearDown(client.close);
    final flow = await client.startLogin(account.server);
    expect(await client.pollLogin(account.server, flow), isNull);
  });

  test('rejects cross-origin login URLs', () async {
    final client = NextcloudClient(
      transport: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'login': 'https://evil.example/flow',
            'poll': {
              'endpoint': 'https://cloud.example/poll',
              'token': 'secret',
            },
          }),
          200,
        ),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.startLogin(account.server),
      throwsA(isA<CloudException>()),
    );
  });

  test(
    'reports failed favorite PROPPATCH even when HTTP status is 207',
    () async {
      final client = NextcloudClient(
        transport: MockClient(
          (_) async => http.Response(
            multistatus(responseEntry(status: 'HTTP/1.1 403 Forbidden')),
            207,
          ),
        ),
      );
      addTearDown(client.close);
      final file = NextcloudClient.parseFiles(
        multistatus(responseEntry()),
        account,
      ).single;
      await expectLater(
        client.setFavorite(account, file, false),
        throwsA(isA<CloudException>()),
      );
    },
  );

  test('uploads a stream without overwriting existing files', () async {
    final client = NextcloudClient(
      transport: MockClient((request) async {
        expect(request.method, 'PUT');
        expect(request.headers['If-None-Match'], '*');
        expect(request.body, 'hello');
        expect(request.followRedirects, isFalse);
        return http.Response('', 412);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.upload(
        account,
        ['hello.txt'],
        Stream.value(utf8.encode('hello')),
        5,
      ),
      throwsA(isA<CloudException>()),
    );
  });

  test('does not expose response bodies in errors', () async {
    final client = NextcloudClient(
      transport: MockClient(
        (_) async => http.Response('secret-password debug trace', 500),
      ),
    );
    addTearDown(client.close);
    await expectLater(
      client.listFiles(account, []),
      throwsA(
        isA<CloudException>().having(
          (e) => e.message,
          'message',
          isNot(contains('secret-password')),
        ),
      ),
    );
  });
}
