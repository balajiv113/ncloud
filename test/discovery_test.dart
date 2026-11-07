import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_discovery.dart';

import 'nextcloud_client_test.dart' show account;
import 'preview_test.dart' show png;

http.Response jsonResponse(Object? value, [int status = 200]) =>
    http.Response(jsonEncode(value), status);

void main() {
  const person = RecognizedPerson(id: 12, name: 'Sample', count: 2);
  final bounds = PhotoMapBounds(south: 40, north: 50, west: 5, east: 15);

  test(
    'people are ordered by photo count, including unnamed groups, with stable ties',
    () async {
      final client = NextcloudClient(
        transport: MockClient(
          (request) async => jsonResponse([
            {'id': 7, 'name': 'Sample A', 'count': 8},
            {'id': 9, 'name': '', 'count': 21},
            {'id': 3, 'name': 'Sample B', 'count': 8},
            {'id': 2, 'name': 'Sample C', 'count': 15},
          ]),
        ),
      );
      addTearDown(client.close);
      final people = await client.people(account);
      expect(people!.map((p) => p.count), [21, 15, 8, 8]);
      expect(people.map((p) => p.id), [9, 2, 3, 7]);
    },
  );

  test(
    'people discovery uses authenticated, scoped Recognize clusters',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.method, 'GET');
          expect(
            request.url.path,
            '/nextcloud/index.php/apps/memories/api/clusters/recognize',
          );
          expect(
            request.url.queryParameters['folder'],
            '/Photos/Trip & family',
          );
          expect(request.url.queryParameters['recursive'], '1');
          expect(request.headers['Authorization'], account.authorization);
          expect(request.followRedirects, isFalse);
          return jsonResponse([
            {
              'id': 12,
              'name': 'Sample',
              'count': 2,
              'cover': '41',
              'cover_etag': 'rev',
            },
            {'id': 13, 'name': '', 'count': 1},
          ]);
        }),
      );
      addTearDown(client.close);
      final people = await client.people(
        account,
        path: ['Photos', 'Trip & family'],
      );
      expect(people!.map((p) => p.id), [12, 13]);
      expect(people.first.cover, 41);
      expect(people.first.coverEtag, 'rev');
      expect(people.first.named, isTrue);
      expect(people.last.named, isFalse);
    },
  );

  test(
    'people discovery returns Memories clusters without a DAV verification request',
    () async {
      for (var session = 0; session < 2; session++) {
        var calls = 0;
        final client = NextcloudClient(
          transport: MockClient((request) async {
            calls++;
            expect(request.method, 'GET');
            expect(request.url.path, endsWith('/clusters/recognize'));
            return jsonResponse([
              {'id': 12, 'name': 'Removed', 'count': 100},
              {'id': 13, 'name': '', 'count': 1},
              {'id': 14, 'name': 'Visible & family', 'count': 2},
            ]);
          }),
        );
        addTearDown(client.close);
        expect((await client.people(account))!.map((p) => p.id), [12, 14, 13]);
        expect(calls, 1);
      }
    },
  );

  test(
    'empty, missing, disabled and failed discovery remain distinct',
    () async {
      for (final status in [200, 404, 405, 412, 401, 403, 500]) {
        final client = NextcloudClient(
          transport: MockClient(
            (_) async =>
                status == 200 ? jsonResponse([]) : http.Response('', status),
          ),
        );
        addTearDown(client.close);
        final result = client.people(account, optional: true);
        if (status == 200) {
          expect(await result, isEmpty);
        } else if (status == 404 || status == 405) {
          expect(await result, isNull);
        } else if (status == 412) {
          await expectLater(
            result,
            throwsA(
              isA<CloudException>().having(
                (e) => e.message,
                'message',
                contains('Recognize'),
              ),
            ),
          );
        } else {
          await expectLater(result, throwsA(isA<CloudException>()));
        }
      }
    },
  );

  test(
    'person face preview is authenticated and uses a stable cluster ID',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.url.path, endsWith('/clusters/recognize/preview'));
          expect(request.url.queryParameters['name'], '12');
          expect(request.headers['Authorization'], account.authorization);
          expect(request.url.userInfo, isEmpty);
          return http.Response.bytes(png, 200);
        }),
      );
      addTearDown(client.close);
      expect(await client.personPreview(account, person), png);
    },
  );

  test(
    'people and map day counts and photo details use identical filters',
    () async {
      final queries = <Map<String, String>>[];
      final client = NextcloudClient(
        transport: MockClient((request) async {
          queries.add(request.url.queryParameters);
          if (request.url.path.endsWith('/days')) {
            return jsonResponse([
              {'dayid': 21000, 'count': 1},
            ]);
          }
          return jsonResponse([
            {
              'fileid': 42,
              'dayid': 21000,
              'basename': 'photo.jpg',
              'etag': 'rev',
            },
          ]);
        }),
      );
      addTearDown(client.close);
      await client.timelineDays(
        account,
        path: ['Photos'],
        person: person,
        mapBounds: bounds,
      );
      final files = await client.timelineDayFiles(
        account,
        [21000],
        path: ['Photos'],
        person: person,
        mapBounds: bounds,
        resolvePaths: false,
      );
      expect(queries, hasLength(2));
      expect(queries.first, queries.last);
      expect(queries.first['recognize'], '${account.userId}/12');
      expect(queries.first['mapbounds'], '40.0,50.0,5.0,15.0');
      expect(queries.first['nopreload'], '1');
      expect(files.single.id, '42');
      expect(files.single.pending, isTrue);
    },
  );

  test(
    'map clusters query only the viewport and preserve nullable previews',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.url.path, endsWith('/map/clusters'));
          expect(request.url.queryParameters['bounds'], bounds.query);
          expect(request.url.queryParameters['zoom'], '8');
          expect(request.url.queryParameters['folder'], '/Photos');
          expect(request.headers['Authorization'], account.authorization);
          return jsonResponse([
            {
              'id': 21,
              'center': [45.8, 9.2],
              'count': 136.0,
              'preview': {'fileid': 42, 'dayid': 21000, 'etag': 'rev'},
            },
            {
              'id': 22,
              'center': [46.0, 10.1],
              'count': 2,
              'preview': null,
            },
          ]);
        }),
      );
      addTearDown(client.close);
      final clusters = await client.mapClusters(
        account,
        bounds: bounds,
        zoom: 8,
        path: ['Photos'],
      );
      expect(clusters.map((c) => c.count), [136, 2]);
      expect(clusters.first.location.latitude, 45.8);
      expect(clusters.first.location.longitude, 9.2);
      expect(clusters.first.previewId, 42);
      expect(clusters.first.previewEtag, 'rev');
      expect(clusters.last.previewId, isNull);
    },
  );

  test('map defaults to all photos without a person or album filter', () async {
    final client = NextcloudClient(
      transport: MockClient((request) async {
        expect(request.url.queryParameters['folder'], '/');
        expect(request.url.queryParameters.containsKey('recognize'), isFalse);
        expect(request.url.queryParameters.containsKey('fav'), isFalse);
        return jsonResponse([]);
      }),
    );
    addTearDown(client.close);
    await client.mapClusters(account, bounds: bounds, zoom: 8);
    await client.timelineDays(account, mapBounds: bounds);
    await client.timelineDayFiles(
      account,
      [21000],
      mapBounds: bounds,
      resolvePaths: false,
    );
  });

  test(
    'initial map position accepts database numeric strings and missing GPS',
    () async {
      final positions = <Object?>[
        {'lat': '45.8', 'lon': '9.2'},
        null,
      ];
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.url.path, endsWith('/map/init'));
          expect(request.headers['Authorization'], account.authorization);
          return jsonResponse({'pos': positions.removeAt(0)});
        }),
      );
      addTearDown(client.close);
      final position = await client.mapPosition(account);
      expect(position!.latitude, 45.8);
      expect(position.longitude, 9.2);
      expect(await client.mapPosition(account), isNull);
    },
  );

  test(
    'malformed responses and invalid geographic input are rejected',
    () async {
      for (final row in [
        {'id': 0, 'name': '', 'count': 1},
        {'id': 1, 'name': '', 'count': -1},
        {'id': 1, 'name': '', 'count': 1, 'cover': 'invalid'},
      ]) {
        expect(() => parseNextcloudPerson(row), throwsFormatException);
      }
      expect(() => PhotoLocation(double.nan, 0), throwsFormatException);
      expect(() => PhotoLocation(91, 0), throwsFormatException);
      expect(() => PhotoLocation(0, -181), throwsFormatException);
      expect(
        () => PhotoMapBounds(south: 10, north: -10, west: 0, east: 20),
        throwsFormatException,
      );
      expect(
        () => PhotoMapBounds(south: -10, north: 10, west: 170, east: -170),
        throwsFormatException,
      );
      expect(
        () => parseNextcloudMapCluster({
          'id': 1,
          'center': [40],
          'count': 2,
        }),
        throwsFormatException,
      );
      expect(
        () => parseNextcloudMapCluster({
          'id': 1,
          'center': [40, 10],
          'count': 1.5,
        }),
        throwsFormatException,
      );
      var network = false;
      final client = NextcloudClient(
        transport: MockClient((_) async {
          network = true;
          return jsonResponse([]);
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.mapClusters(account, bounds: bounds, zoom: 23),
        throwsFormatException,
      );
      expect(network, isFalse);
    },
  );

  test('invalid JSON shapes do not become empty success results', () async {
    for (final body in <Object>[
      {},
      [false],
      [
        {'id': 'bad'},
      ],
    ]) {
      final client = NextcloudClient(
        transport: MockClient((_) async => jsonResponse(body)),
      );
      addTearDown(client.close);
      await expectLater(client.people(account), throwsFormatException);
      await expectLater(
        client.mapClusters(account, bounds: bounds, zoom: 4),
        throwsFormatException,
      );
    }
    final client = NextcloudClient(
      transport: MockClient((_) async => jsonResponse({})),
    );
    addTearDown(client.close);
    await expectLater(client.mapPosition(account), throwsFormatException);
  });
}
