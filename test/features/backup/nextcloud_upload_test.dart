import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import '../../nextcloud_client_test.dart' show account;

NextcloudClient clientFor(http.Response Function(http.Request) handler) {
  final client = NextcloudClient(
    transport: MockClient((r) async => handler(r)),
  );
  addTearDown(client.close);
  return client;
}

String propfind(String props) =>
    '''
<d:multistatus xmlns:d="DAV:" xmlns:oc="http://owncloud.org/ns">
  <d:response>
    <d:href>/nextcloud/remote.php/dav/files/alice/Backup/a.jpg</d:href>
    <d:propstat><d:prop>$props</d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>''';

void main() {
  group('uploadNew', () {
    test('never overwrites, sends the fingerprint and modified time', () async {
      late http.Request seen;
      final client = clientFor((request) {
        seen = request;
        return http.Response(
          '',
          201,
          headers: {'oc-etag': '"abc"', 'etag': '"zzz"', 'oc-fileid': '77'},
        );
      });
      final result = await client.uploadNew(
        account,
        ['Backup', 'a.jpg'],
        Stream.value([1, 2, 3]),
        3,
        sha1: 'ab12',
        modified: DateTime.fromMillisecondsSinceEpoch(1700000123456),
      );
      expect(seen.method, 'PUT');
      expect(seen.headers['If-None-Match'], '*');
      expect(seen.headers['OC-Checksum'], 'SHA1:ab12');
      expect(seen.headers['X-OC-Mtime'], '1700000123');
      expect(seen.bodyBytes, [1, 2, 3]);
      expect(result.etag, '"abc"', reason: 'the server\'s own revision wins');
      expect(result.fileId, '77');
    });

    test('leaves the extra headers out when it has nothing to say', () async {
      late http.Request seen;
      final client = clientFor((request) {
        seen = request;
        return http.Response('', 204, headers: {'etag': '"only"'});
      });
      final result = await client.uploadNew(
        account,
        ['a.jpg'],
        Stream.value([9]),
        1,
      );
      expect(seen.headers.containsKey('OC-Checksum'), isFalse);
      expect(seen.headers.containsKey('X-OC-Mtime'), isFalse);
      expect(result.etag, '"only"');
    });

    test('reports why the server refused', () async {
      Future<CloudException> refuse(int status) async {
        final client = clientFor((_) => http.Response('', status));
        try {
          await client.uploadNew(account, ['a.jpg'], Stream.value([1]), 1);
        } on CloudException catch (e) {
          return e;
        }
        fail('expected a refusal');
      }

      expect((await refuse(412)).statusCode, 412);
      expect((await refuse(507)).statusCode, 507);
      expect((await refuse(401)).statusCode, 401);
      expect((await refuse(503)).retryable, isTrue);
    });
  });

  group('stat', () {
    test('reads size, revision and the stored fingerprint', () async {
      late http.Request seen;
      final client = clientFor((request) {
        seen = request;
        return http.Response(
          propfind(
            '<d:resourcetype/><d:getcontentlength>2048</d:getcontentlength>'
            '<d:getetag>"rev1"</d:getetag>'
            '<oc:checksums><oc:checksum>MD5:aaaa SHA1:ABCDEF12 ADLER32:1234</oc:checksum></oc:checksums>',
          ),
          207,
        );
      });
      final stat = (await client.stat(account, ['Backup', 'a.jpg']))!;
      expect(seen.method, 'PROPFIND');
      expect(seen.headers['Depth'], '0');
      expect(stat.isDirectory, isFalse);
      expect(stat.size, 2048);
      expect(stat.etag, '"rev1"');
      expect(stat.sha1, 'abcdef12');
    });

    test(
      'knows a folder, a file with no fingerprint, and a missing file',
      () async {
        final folder = clientFor(
          (_) => http.Response(
            propfind(
              '<d:resourcetype><d:collection/></d:resourcetype><d:getetag>"f"</d:getetag>',
            ),
            207,
          ),
        );
        expect((await folder.stat(account, ['Backup']))!.isDirectory, isTrue);
        final plain = clientFor(
          (_) => http.Response(
            propfind(
              '<d:resourcetype/><d:getcontentlength>5</d:getcontentlength><d:getetag>"p"</d:getetag>',
            ),
            207,
          ),
        );
        expect((await plain.stat(account, ['a']))!.sha1, isNull);
        final missing = clientFor((_) => http.Response('', 404));
        expect(await missing.stat(account, ['nope']), isNull);
      },
    );

    test('other errors are reported, not hidden as "missing"', () async {
      final client = clientFor((_) => http.Response('', 401));
      await expectLater(
        client.stat(account, ['a']),
        throwsA(isA<CloudException>()),
      );
    });
  });

  group('ensureFolder', () {
    test('creates a folder and accepts one that is already there', () async {
      final methods = <String>[];
      final created = clientFor((r) {
        methods.add(r.method);
        return http.Response('', 201);
      });
      await created.ensureFolder(account, ['Backup', 'New']);
      final existing = clientFor((_) => http.Response('', 405));
      await existing.ensureFolder(account, ['Backup', 'New']);
      expect(methods, ['MKCOL']);
    });

    test('a missing parent is an error', () async {
      final client = clientFor((_) => http.Response('', 409));
      await expectLater(
        client.ensureFolder(account, ['Missing', 'New']),
        throwsA(isA<CloudException>()),
      );
    });
  });
}
