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

  group('uploadResumable', () {
    String multistatus(Map<String, int> pieces) =>
        '''
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/remote.php/dav/uploads/alice/x/</d:href></d:response>
  <d:response><d:href>/remote.php/dav/uploads/alice/x/.file</d:href>
    <d:propstat><d:prop><d:getcontentlength>25</d:getcontentlength></d:prop></d:propstat></d:response>
  ${pieces.entries.map((e) => '<d:response><d:href>/remote.php/dav/uploads/alice/x/${e.key}</d:href><d:propstat><d:prop><d:getcontentlength>${e.value}</d:getcontentlength></d:prop></d:propstat></d:response>').join()}
</d:multistatus>''';

    Stream<List<int>> Function(int, int) source(List<int> data) =>
        (start, end) => Stream.value(data.sublist(start, end));

    test(
      'makes the upload, sends each piece, then joins them without overwriting',
      () async {
        final seen = <http.Request>[];
        final client = NextcloudClient(
          chunkBytes: 10,
          transport: MockClient((request) async {
            seen.add(request);
            return switch (request.method) {
              'MKCOL' => http.Response('', 201),
              'PROPFIND' => http.Response(multistatus({}), 207),
              'PUT' => http.Response('', 201),
              _ => http.Response(
                '',
                201,
                headers: {'oc-etag': '"joined"', 'oc-fileid': '9'},
              ),
            };
          }),
        );
        addTearDown(client.close);
        final data = List.generate(25, (i) => i);
        final sent = <int>[];
        final result = await client.uploadResumable(
          account,
          ['Backup', 'big.mp4'],
          source(data),
          25,
          sha1: 'abc123',
          modified: DateTime.fromMillisecondsSinceEpoch(1700000123456),
          onProgress: sent.add,
        );
        expect(seen.map((r) => r.method), [
          'MKCOL',
          'PROPFIND',
          'PUT',
          'PUT',
          'PUT',
          'MOVE',
        ]);
        final folder = seen.first.url;
        expect(
          folder.path,
          startsWith('/nextcloud/remote.php/dav/uploads/alice/ncloud-'),
        );
        expect(
          seen.first.headers['Destination'],
          contains('/remote.php/dav/files/alice/Backup/big.mp4'),
        );
        expect(seen[2].url.path, '${folder.path}/00001');
        expect(seen[3].url.path, '${folder.path}/00002');
        expect(seen[4].url.path, '${folder.path}/00003');
        expect(seen[2].bodyBytes, data.sublist(0, 10));
        expect(seen[4].bodyBytes, data.sublist(20, 25));
        final join = seen.last;
        expect(join.url.path, '${folder.path}/.file');
        expect(join.headers['Overwrite'], 'F');
        expect(join.headers['OC-Total-Length'], '25');
        expect(join.headers['OC-Checksum'], 'SHA1:abc123');
        expect(join.headers['X-OC-Mtime'], '1700000123');
        expect(result.etag, '"joined"');
        expect(sent.last, 25);
        expect(sent, orderedEquals([...sent]..sort()));
      },
    );

    test('carries on after the pieces that are already there', () async {
      final puts = <String>[];
      final client = NextcloudClient(
        chunkBytes: 10,
        transport: MockClient((request) async {
          switch (request.method) {
            case 'MKCOL':
              return http.Response('', 405);
            case 'PROPFIND':
              // The first piece is whole, the second is cut short.
              return http.Response(multistatus({'00001': 10, '00002': 4}), 207);
            case 'PUT':
              puts.add(request.url.pathSegments.last);
              return http.Response('', 201);
          }
          return http.Response('', 201, headers: {'etag': '"e"'});
        }),
      );
      addTearDown(client.close);
      final sent = <int>[];
      await client.uploadResumable(
        account,
        ['a.mp4'],
        source(List.filled(25, 1)),
        25,
        sha1: 'ab',
        onProgress: sent.add,
      );
      expect(puts, ['00002', '00003']);
      expect(sent.first, 10, reason: 'the piece already there counts at once');
    });

    test(
      'a destination that exists is refused, and the pieces are cleared',
      () async {
        final methods = <String>[];
        final client = NextcloudClient(
          chunkBytes: 10,
          transport: MockClient((request) async {
            methods.add(request.method);
            return switch (request.method) {
              'MKCOL' => http.Response('', 201),
              'PROPFIND' => http.Response(multistatus({}), 207),
              'PUT' => http.Response('', 201),
              'MOVE' => http.Response('', 412),
              _ => http.Response('', 204),
            };
          }),
        );
        addTearDown(client.close);
        await expectLater(
          client.uploadResumable(
            account,
            ['a.mp4'],
            source(List.filled(5, 1)),
            5,
            sha1: 'ab',
          ),
          throwsA(
            isA<CloudException>().having((e) => e.statusCode, 'status', 412),
          ),
        );
        expect(methods.last, 'DELETE');
      },
    );

    test('a dropped connection is a retryable failure', () async {
      final client = NextcloudClient(
        chunkBytes: 10,
        transport: MockClient((request) async {
          if (request.method == 'PUT') throw http.ClientException('reset');
          return request.method == 'PROPFIND'
              ? http.Response(multistatus({}), 207)
              : http.Response('', 201);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.uploadResumable(
          account,
          ['a.mp4'],
          source(List.filled(5, 1)),
          5,
          sha1: 'ab',
        ),
        throwsA(
          isA<CloudException>().having((e) => e.retryable, 'retryable', isTrue),
        ),
      );
    });

    test('the same file and place always use the same upload folder', () async {
      final folders = <String>[];
      final client = NextcloudClient(
        chunkBytes: 10,
        transport: MockClient((request) async {
          if (request.method == 'MKCOL') folders.add(request.url.path);
          return request.method == 'PROPFIND'
              ? http.Response(multistatus({}), 207)
              : http.Response('', 201, headers: {'etag': '"e"'});
        }),
      );
      addTearDown(client.close);
      for (final where in [
        ['a.mp4'],
        ['a.mp4'],
        ['b.mp4'],
      ]) {
        await client.uploadResumable(
          account,
          where,
          source(List.filled(5, 1)),
          5,
          sha1: 'ab',
        );
      }
      expect(folders[0], folders[1]);
      expect(folders[2], isNot(folders[0]));
    });
  });
}
