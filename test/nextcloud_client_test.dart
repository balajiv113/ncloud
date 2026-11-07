import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';

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
  test('endpoint preserves subfolder installs and encoded path segments', () {
    final server = normalizeServer(' https://example.com/nextcloud/ ');
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

  test('DAV file revisions are retained for conditional folder sync', () {
    final file = NextcloudClient.parseFiles(
      multistatus(
        responseEntry(properties: '<d:getetag>"revision-1"</d:getetag>'),
      ),
      account,
    ).single;
    expect(file.etag, '"revision-1"');
  });

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
      expect(
        (await client.listFolder(account, ['Photos'])).children,
        hasLength(1),
      );
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
    expect((await client.searchPage(account)).files, hasLength(1));
  });

  test(
    'folder listing is scoped, direct and deduplicated by actual path',
    () async {
      final root = '/nextcloud/remote.php/dav/files/alice';
      final client = NextcloudClient(
        transport: MockClient(
          (_) async => http.Response(
            multistatus(
              [
                responseEntry(href: '$root/Other/'),
                responseEntry(href: '$root/Photos/'),
                responseEntry(
                  href: '$root/Photos/Trip/',
                  properties:
                      '<d:resourcetype><d:collection/></d:resourcetype>',
                ),
                responseEntry(href: '$root/Photos/Trip/'),
                responseEntry(href: '$root/Photos/Trip/Trip/'),
                responseEntry(href: '$root/Other/Trip/'),
              ].join(),
            ),
            207,
          ),
        ),
      );
      addTearDown(client.close);
      final result = await client.listFolder(account, ['Photos']);
      expect(result.self?.path, ['Photos']);
      expect(result.children.map((f) => f.path), [
        ['Photos', 'Trip'],
      ]);
    },
  );

  test(
    'scoped SEARCH uses literal XML-escaped paths and SearchDAV offsets',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(
            request.body,
            contains('<d:href>/files/alice/Album &amp; family #1</d:href>'),
          );
          expect(
            request.body,
            contains('<sd:firstresult>200</sd:firstresult>'),
          );
          expect(
            request.body,
            contains('xmlns:sd="https://github.com/icewind1991/SearchDAV/ns"'),
          );
          return http.Response(multistatus(''), 207);
        }),
      );
      addTearDown(client.close);
      await client.searchPage(
        account,
        path: ['Album & family #1'],
        offset: 200,
      );
    },
  );

  test(
    'non-recursive SEARCH drops nested files but pages by raw count',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          return http.Response(
            multistatus(
              responseEntry() +
                  responseEntry(
                    href:
                        '/nextcloud/remote.php/dav/files/alice/Photos/Japan/a.jpg',
                    name: 'a.jpg',
                  ),
            ),
            207,
          );
        }),
      );
      addTearDown(client.close);
      final page = await client.searchPage(
        account,
        path: ['Photos'],
        recursive: false,
      );
      expect(page.files.map((f) => f.path), [
        ['Photos', 'Beach & sun.jpg'],
      ]);
      expect(page.scanned, 2);
      final all = await client.searchPage(account, path: ['Photos']);
      expect(all.files, hasLength(2));
    },
  );

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
    expect(flow.login.path, '/nextcloud/login/v2/flow/abc');
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
      client.uploadNew(
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
      client.listFolder(account, []),
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
