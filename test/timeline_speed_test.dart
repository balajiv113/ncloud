import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;
import 'memories_test.dart' show davForIds, indexedTransport, jsonResponse;
import 'nextcloud_client_test.dart' show account, multistatus;
import 'preview_test.dart' show photo, png;

Uint8List multipreviewBody(Iterable<String> ids) {
  final out = BytesBuilder();
  for (final id in ids) {
    final header = utf8.encode(
      jsonEncode({'reqid': id, 'len': png.length, 'type': 'image/png'}),
    );
    out
      ..addByte(header.length)
      ..add(header)
      ..add(png);
  }
  return out.takeBytes();
}

Future<void> settle(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  test('multipreview records parse into per-request thumbnails', () {
    final parsed = NextcloudClient.parseMultipreview(
      multipreviewBody(['7', '9']),
    );
    expect(parsed.keys, ['7', '9']);
    expect(parsed['9'], png);
    expect(
      () => NextcloudClient.parseMultipreview(
        Uint8List.sublistView(multipreviewBody(['7']), 0, 10),
      ),
      throwsFormatException,
    );
  });

  test(
    'visible tiles share one Memories multipreview request; missing ones fall back',
    () async {
      final requests = <http.Request>[];
      final controller = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            requests.add(request);
            if (request.url.path.endsWith('/multipreview')) {
              expect(request.method, 'POST');
              final files = (jsonDecode(request.body) as Map)['files'] as List;
              final ids = [
                for (final f in files) (f as Map)['reqid'] as String,
              ];
              return http.Response.bytes(
                multipreviewBody(ids.where((id) => id != '3')),
                200,
              );
            }
            expect(request.url.queryParameters['fileId'], '3');
            return http.Response.bytes(png, 200);
          }),
        ),
      )..account = account;
      controller.memoriesAvailable = true;
      addTearDown(controller.dispose);
      final results = await Future.wait([
        for (var i = 0; i < 6; i++) controller.preview(photo(id: '$i')),
      ]);
      expect(results, everyElement(png));
      expect(
        requests.where((r) => r.url.path.endsWith('/multipreview')),
        hasLength(1),
      );
      expect(requests, hasLength(2));
      expect(controller.cachedPreview(photo(id: '5')), png);
    },
  );

  test(
    'the pathless Timeline paints from Memories rows and finds paths in the background',
    () async {
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(transport: indexedTransport(calls)),
        pathlessTimeline: true,
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(c.error, isNull);
      expect(
        calls.where((r) => r.url.path.contains('/days/')),
        hasLength(1),
        reason: 'metadata-only batches cover many days per request',
      );
      expect(c.items, hasLength(1500));
      expect(c.items.first.name, 'photo.jpg');
      expect(c.items.first.captureDay, 21000);
      final first = c.items.first;
      final resolved = await c.resolve(first);
      expect(resolved.path, ['Photos', 'photo-${first.id}.jpg']);
      await settle(() => c.items.every((f) => !f.pending));
      expect(c.items.where((f) => f.pending), isEmpty);
      expect(c.items, hasLength(1500));
      expect(c.items.first.captureDay, 21000);
      expect(c.items.first.etag, 'revision-21000');
      expect(
        calls.where((r) => r.method == 'SEARCH').length,
        inInclusiveRange(15, 17),
      );
    },
  );

  test(
    'server changes are detected from the day index and only changed days reload',
    () async {
      var counts = {for (var i = 0; i < 30; i++) 21000 - i: 60};
      final calls = <http.Request>[];
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            calls.add(request);
            if (request.method == 'PROPFIND') {
              return http.Response(multistatus(''), 207);
            }
            if (request.method == 'SEARCH') return davForIds(request);
            if (request.url.path.endsWith('/days')) {
              return jsonResponse([
                for (final MapEntry(:key, :value) in counts.entries)
                  {'dayid': key, 'count': value},
              ]);
            }
            final days = request.url.pathSegments.last
                .split(',')
                .map(int.parse);
            return jsonResponse([
              for (final day in days)
                for (var i = 0; i < counts[day]!; i++)
                  {'fileid': day * 100 + i, 'dayid': day, 'etag': 'r'},
            ]);
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      await c.load();
      expect(c.items, hasLength(180));
      expect(await c.checkForChanges(), isFalse);
      expect(c.timelineChanged, isFalse);
      counts = {21001: 3, ...counts, 21000: 61};
      expect(await c.checkForChanges(), isTrue);
      expect(c.timelineChanged, isTrue);
      expect(c.newPhotos, 4);
      final before = calls.length;
      c.applyChanges();
      expect(c.timelineChanged, isFalse);
      expect(c.indexedDays.first.id, 21001);
      await settle(() => !c.fetchingDays);
      expect(c.items.where((f) => f.captureDay == 21000), hasLength(61));
      expect(c.items.where((f) => f.captureDay == 20999), hasLength(60));
      final reloads = calls
          .skip(before)
          .where((r) => r.url.path.contains('/days/'))
          .map((r) => r.url.pathSegments.last)
          .toList();
      expect(reloads, ['21000']);
    },
  );
}
