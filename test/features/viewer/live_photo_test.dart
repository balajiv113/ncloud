import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/viewer/live_photo_clips.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import '../../memories_test.dart' show jsonResponse;
import '../../nextcloud_client_test.dart' show account;

const live = CloudFile(
  path: ['Photos', 'IMG_1.HEIC'],
  name: 'IMG_1.HEIC',
  isDirectory: false,
  contentType: 'image/heic',
  id: '42',
  etag: 'abc',
  liveId: 'apple-id',
);

Uint8List movie(String brand) => Uint8List.fromList([
  0,
  0,
  0,
  20,
  ...'ftyp'.codeUnits,
  ...brand.codeUnits,
  1,
  2,
  3,
  4,
]);

void main() {
  group('Live Photo rows', () {
    test('keep the live id, and photos without one are not live', () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          if (!request.url.path.contains('/days/')) {
            return http.Response('', 404);
          }
          return jsonResponse([
            {
              'fileid': 1,
              'dayid': 100,
              'epoch': 8640000,
              'basename': 'a.heic',
              'liveid': 'apple-id',
              'mimetype': 'image/heic',
            },
            {
              'fileid': 2,
              'dayid': 100,
              'epoch': 8640001,
              'basename': 'b.jpg',
              'mimetype': 'image/jpeg',
            },
          ]);
        }),
      );
      addTearDown(client.close);
      final files = await client.timelineDayFiles(account, [
        100,
      ], resolvePaths: false);
      expect(files.map((f) => f.isLive), [true, false]);
      expect(files.first.liveId, 'apple-id');
    });

    test('the live id survives saving and copying', () {
      expect(CloudFile.fromJson(live.toJson()).liveId, 'apple-id');
      expect(live.withFavorite(true).liveId, 'apple-id');
      expect(live.withRevision('r2').liveId, 'apple-id');
      expect(live.atPath(['Other', 'x.heic']).liveId, 'apple-id');
      expect(
        live.withCaptureDate(DateTime.utc(2024), 'r', day: 1).liveId,
        'apple-id',
      );
    });
  });

  group('livePhotoVideo', () {
    NextcloudClient clientFor(
      FutureOr<http.StreamedResponse> Function(http.BaseRequest request) send,
      List<http.BaseRequest> seen,
    ) => NextcloudClient(
      transport: _Transport((request) async {
        seen.add(request);
        return send(request);
      }),
    );

    http.StreamedResponse ok(List<int> bytes, {Map<String, String>? headers}) =>
        http.StreamedResponse(
          Stream.value(bytes),
          200,
          contentLength: bytes.length,
          headers: headers ?? {},
        );

    test(
      'asks Memories for the clip with the live id and credentials',
      () async {
        final seen = <http.BaseRequest>[];
        final client = clientFor((_) => ok([1, 2, 3]), seen);
        addTearDown(client.close);
        final bytes = await client.livePhotoVideo(account, live);
        expect(bytes, [1, 2, 3]);
        final request = seen.single;
        expect(
          request.url.path,
          endsWith('/apps/memories/api/video/livephoto/42'),
        );
        expect(request.url.queryParameters['liveid'], 'apple-id');
        expect(request.headers['Authorization'], account.authorization);
      },
    );

    test(
      'follows a redirect to the same server and keeps the credentials',
      () async {
        final seen = <http.BaseRequest>[];
        final client = clientFor((request) {
          if (seen.length == 1) {
            return http.StreamedResponse(
              const Stream.empty(),
              302,
              headers: {
                'location': '/nextcloud/index.php/apps/memories/api/stream/77',
              },
            );
          }
          return ok([9, 9]);
        }, seen);
        addTearDown(client.close);
        expect(await client.livePhotoVideo(account, live), [9, 9]);
        expect(seen, hasLength(2));
        expect(seen.last.url.path, endsWith('/stream/77'));
        expect(seen.last.headers['Authorization'], account.authorization);
      },
    );

    test('never sends credentials to another server', () async {
      final seen = <http.BaseRequest>[];
      final client = clientFor(
        (_) => http.StreamedResponse(
          const Stream.empty(),
          302,
          headers: {'location': 'https://evil.example/clip.mov'},
        ),
        seen,
      );
      addTearDown(client.close);
      await expectLater(
        client.livePhotoVideo(account, live),
        throwsA(isA<CloudException>()),
      );
      expect(seen, hasLength(1));
    });

    test(
      'says so when the server has no clip, and refuses endless redirects',
      () async {
        final missing = NextcloudClient(
          transport: _Transport(
            (_) => http.StreamedResponse(const Stream.empty(), 404),
          ),
        );
        addTearDown(missing.close);
        await expectLater(
          missing.livePhotoVideo(account, live),
          throwsA(
            isA<CloudException>().having(
              (e) => e.message,
              'message',
              contains('not available'),
            ),
          ),
        );
        final loop = NextcloudClient(
          transport: _Transport(
            (_) => http.StreamedResponse(
              const Stream.empty(),
              302,
              headers: {'location': '/nextcloud/loop'},
            ),
          ),
        );
        addTearDown(loop.close);
        await expectLater(
          loop.livePhotoVideo(account, live),
          throwsA(isA<CloudException>()),
        );
      },
    );

    test(
      'refuses a clip that is too large and a photo that is not live',
      () async {
        final big = NextcloudClient(
          transport: _Transport(
            (_) => http.StreamedResponse(
              const Stream.empty(),
              200,
              contentLength: 65 * 1024 * 1024,
            ),
          ),
        );
        addTearDown(big.close);
        await expectLater(
          big.livePhotoVideo(account, live),
          throwsA(isA<CloudException>()),
        );
        await expectLater(
          big.livePhotoVideo(
            account,
            const CloudFile(
              path: ['a'],
              name: 'a',
              isDirectory: false,
              id: '1',
            ),
          ),
          throwsA(isA<CloudException>()),
        );
      },
    );
  });

  group('LivePhotoClips', () {
    late Directory root;
    setUp(() async => root = await Directory.systemTemp.createTemp('live'));
    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'downloads once, shares concurrent requests, and replays from disk',
      () async {
        final backend = _LiveBackend(movie('qt  '));
        final clips = LivePhotoClips(
          client: backend,
          directory: () async => root,
        );
        final both = await Future.wait([
          clips.clip(account, live),
          clips.clip(account, live),
        ]);
        expect(both.first.path, both.last.path);
        expect(backend.requests, 1);
        expect((await clips.clip(account, live)).path, both.first.path);
        expect(backend.requests, 1);
        expect(await both.first.readAsBytes(), movie('qt  '));
      },
    );

    test('names the file for how the player reads it', () async {
      expect(LivePhotoClips.extensionFor(movie('qt  ')), '.mov');
      expect(LivePhotoClips.extensionFor(movie('isom')), '.mp4');
      expect(LivePhotoClips.extensionFor(Uint8List(3)), '.mp4');
    });

    test('a new version of the photo gets its own clip', () async {
      final backend = _LiveBackend(movie('isom'));
      final clips = LivePhotoClips(
        client: backend,
        directory: () async => root,
      );
      final first = await clips.clip(account, live);
      final second = await clips.clip(account, live.withRevision('changed'));
      expect(first.path, isNot(second.path));
      expect(backend.requests, 2);
    });

    test('keeps only the most recent clips', () async {
      final backend = _LiveBackend(movie('qt  '));
      final clips = LivePhotoClips(
        client: backend,
        directory: () async => root,
        keep: 2,
      );
      for (var i = 0; i < 4; i++) {
        await clips.clip(
          account,
          CloudFile(
            path: ['p$i'],
            name: 'p$i',
            isDirectory: false,
            id: '$i',
            etag: 'e',
            liveId: 'l',
          ),
        );
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
      expect(root.listSync(), hasLength(2));
    });

    test('a failed download is not remembered', () async {
      final backend = _LiveBackend(movie('qt  '))..failNext = true;
      final clips = LivePhotoClips(
        client: backend,
        directory: () async => root,
      );
      await expectLater(
        clips.clip(account, live),
        throwsA(isA<CloudException>()),
      );
      expect((await clips.clip(account, live)).existsSync(), isTrue);
    });
  });
}

class _LiveBackend implements CloudBackend {
  _LiveBackend(this.bytes);

  final Uint8List bytes;
  int requests = 0;
  bool failNext = false;

  @override
  Future<Uint8List> livePhotoVideo(Account account, CloudFile file) async {
    requests++;
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (failNext) {
      failNext = false;
      throw const CloudException('The live video is not available.');
    }
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _Transport extends http.BaseClient {
  _Transport(this._send);

  final FutureOr<http.StreamedResponse> Function(http.BaseRequest request)
  _send;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async =>
      _send(request);
}
