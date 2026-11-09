import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:latlong2/latlong.dart';
import 'package:ncloud/app/browse_target.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/app/shell/app_shell.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/features/map/photo_map_screen.dart';

import '../../app_test.dart' show MemoryStore;
import '../../discovery_test.dart' show jsonResponse;
import '../../nextcloud_client_test.dart' show account;
import '../../preview_test.dart' show png;

void main() {
  testWidgets('Albums opens Map and its area opens the existing photo grid', (
    tester,
  ) async {
    final c =
        AppController(
            store: MemoryStore(),
            client: NextcloudClient(
              transport: MockClient((request) async {
                expect(
                  request.url.queryParameters.containsKey('recognize'),
                  isFalse,
                );
                if (request.url.path.endsWith('/map/init')) {
                  return jsonResponse({
                    'pos': {'lat': 45.0, 'lon': 9.0},
                  });
                }
                if (request.url.path.endsWith('/map/clusters')) {
                  return jsonResponse([
                    {
                      'id': 1,
                      'center': [45.0, 9.0],
                      'count': 1,
                    },
                  ]);
                }
                if (request.url.path.endsWith('/days')) {
                  expect(request.url.queryParameters['mapbounds'], isNotNull);
                  return jsonResponse([
                    {'dayid': 21000, 'count': 1},
                  ]);
                }
                if (request.url.path.contains('/days/')) {
                  expect(request.url.queryParameters['mapbounds'], isNotNull);
                  return jsonResponse([
                    {'fileid': 42, 'dayid': 21000, 'basename': 'map-photo.jpg'},
                  ]);
                }
                if (request.url.path.endsWith('/preview')) {
                  return http.Response.bytes(png, 200);
                }
                return http.Response('', 404);
              }),
            ),
          )
          ..account = account
          ..target = const AlbumHomeTarget()
          ..timelineIndexAvailable = true;
    await tester.pumpWidget(
      MaterialApp(
        home: ListenableBuilder(
          listenable: c,
          builder: (_, _) => AppShell(controller: c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Map'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('Map')),
      alignment: 0.4,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Map'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoMapScreen), findsOneWidget);
    await tester.tap(find.text('Open photos in this area'));
    await tester.pumpAndSettle();
    expect(find.byType(PhotoMapScreen), findsNothing);
    expect(find.text('Photos in this area'), findsOneWidget);
    expect(find.bySemanticsLabel('map-photo.jpg'), findsOneWidget);
    expect(c.activeMapBounds, isNotEmpty);
    expect(c.activePerson, isNull);
    expect(find.byTooltip('Album actions'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  test(
    'map viewports split at the antimeridian and normalize world copies',
    () {
      List<PhotoMapBounds> bounds(double west, double east) =>
          PhotoMapBounds.viewport(
            south: -10,
            north: 20,
            west: west,
            east: east,
          );
      expect(bounds(170, 190).map((b) => b.query), [
        '-10.0,20.0,170.0,180.0',
        '-10.0,20.0,-180.0,-170.0',
      ]);
      expect(
        bounds(170, -170).map((b) => b.query),
        bounds(170, 190).map((b) => b.query),
      );
      expect(
        bounds(530, 550).map((b) => b.query),
        bounds(170, 190).map((b) => b.query),
      );
      expect(bounds(-540, 540).single.query, '-10.0,20.0,-180.0,180.0');
      expect(bounds(-30, 40).single.query, '-10.0,20.0,-30.0,40.0');
      expect(() => bounds(double.nan, 40), throwsFormatException);
    },
  );

  test(
    'map areas merge day counts and deduplicate files across wrapped bounds',
    () async {
      final requests = <http.Request>[];
      final client = NextcloudClient(
        transport: MockClient((request) async {
          requests.add(request);
          final query = request.url.queryParameters;
          expect(query['folder'], '/');
          expect(query.containsKey('recognize'), isFalse);
          if (request.url.path.endsWith('/days')) {
            return jsonResponse([
              {'dayid': 21000, 'count': 1},
              if (query['mapbounds']!.contains('170.0,180.0'))
                {'dayid': 20999, 'count': 2},
            ]);
          }
          return jsonResponse([
            {'fileid': 42, 'dayid': 21000, 'basename': 'map.jpg'},
          ]);
        }),
      );
      addTearDown(client.close);
      final bounds = PhotoMapBounds.viewport(
        south: -10,
        north: 20,
        west: 170,
        east: 190,
      );
      final days = (await client.timeline(
        account,
        TimelineQuery(mapBounds: bounds),
      ))!.days!;
      expect(days.map((d) => d.id), [21000, 20999]);
      expect(days.map((d) => d.count), [2, 2]);
      final items = await client.timeline(
        account,
        TimelineQuery(dayIds: [21000], mapBounds: bounds, resolvePaths: false),
      );
      expect(items!.items, hasLength(1));
      expect(requests, hasLength(4));
      await expectLater(
        client.timeline(account, const TimelineQuery(mapBounds: [])),
        throwsFormatException,
      );
    },
  );

  test(
    'opening a map area clears People and paging keeps geographic filters',
    () async {
      final bounds = [PhotoMapBounds(south: 40, north: 50, west: 5, east: 15)];
      var days = 0;
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (request.url.queryParameters.containsKey('recognize')) {
                    return jsonResponse([]);
                  }
                  expect(request.url.queryParameters['recognize'], isNull);
                  expect(
                    request.url.queryParameters['mapbounds'],
                    bounds.single.query,
                  );
                  expect(request.method, 'GET');
                  if (request.url.path.endsWith('/days')) {
                    days++;
                    return jsonResponse([
                      {'dayid': 21000, 'count': 1500},
                      {'dayid': 20999, 'count': 1},
                    ]);
                  }
                  final day = int.parse(request.url.pathSegments.last);
                  return jsonResponse([
                    for (var i = 0; i < (day == 21000 ? 1500 : 1); i++)
                      {
                        'fileid': day * 10000 + i,
                        'dayid': day,
                        'basename': 'map.jpg',
                      },
                  ]);
                }),
              ),
            )
            ..account = account
            ..target = const PersonTarget(
              RecognizedPerson(id: '12', name: 'Sample', count: 10),
            )
            ..timelineIndexAvailable = true;
      addTearDown(c.dispose);
      await c.openMapArea(bounds);
      expect(c.activePerson, isNull);
      expect(c.albumHome, isFalse);
      expect(c.items, hasLength(1500));
      await c.loadNextPage();
      expect(c.items, hasLength(1501));
      await c.openMapArea(bounds);
      expect(
        days,
        1,
        reason: 'map listing uses the existing persistent paging cache',
      );
      await c.openPerson(
        const RecognizedPerson(id: '12', name: 'Sample', count: 10),
      );
      expect(c.activeMapBounds, isNull);
    },
  );

  testWidgets(
    'map shows account-wide pins without requesting third-party tiles',
    (tester) async {
      final requests = <http.Request>[];
      List<PhotoMapBounds>? opened;
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  requests.add(request);
                  expect(
                    request.url.queryParameters.containsKey('recognize'),
                    isFalse,
                  );
                  if (request.url.path.endsWith('/map/init')) {
                    expect(request.url.queryParameters['folder'], '/');
                    expect(request.url.queryParameters['recursive'], '1');
                    return jsonResponse({
                      'pos': {'lat': 45.0, 'lon': 9.0},
                    });
                  }
                  expect(request.url.path, endsWith('/map/clusters'));
                  return jsonResponse([
                    {
                      'id': 1,
                      'center': [45.0, 9.0],
                      'count': 12,
                    },
                  ]);
                }),
              ),
            )
            ..account = account
            ..target = const PersonTarget(
              RecognizedPerson(id: '12', name: 'Sample', count: 10),
            );
      await tester.pumpWidget(
        MaterialApp(
          home: PhotoMapScreen(
            controller: c,
            onOpenArea: (bounds) => opened = bounds,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.byType(TileLayer), findsNothing);
      expect(
        find.bySemanticsLabel('12 photos near 45.00, 9.00'),
        findsOneWidget,
      );
      expect(find.text('Load OpenStreetMap background'), findsOneWidget);
      await tester.tap(find.text('Open photos in this area'));
      expect(opened, isNotEmpty);
      final count = requests.length;
      await tester.tap(find.byTooltip('Zoom in'));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(requests.length, greaterThan(count));
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );

  testWidgets('stale viewport responses cannot overwrite the latest map area', (
    tester,
  ) async {
    final first = Completer<http.Response>();
    var calls = 0;
    final c = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.endsWith('/map/init')) {
            return jsonResponse({
              'pos': {'lat': 45.0, 'lon': 9.0},
            });
          }
          calls++;
          if (calls == 1) return first.future;
          return jsonResponse([
            {
              'id': 2,
              'center': [40.0, 12.0],
              'count': 7,
            },
          ]);
        }),
      ),
    )..account = account;
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoMapScreen(controller: c, onOpenArea: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 350));
    expect(calls, 1);
    tester
        .widget<FlutterMap>(find.byType(FlutterMap))
        .mapController!
        .move(const LatLng(40, 12), 6);
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      calls,
      1,
      reason: 'viewport requests are coalesced, not run concurrently',
    );
    first.complete(
      jsonResponse([
        {
          'id': 1,
          'center': [45.0, 9.0],
          'count': 99,
        },
      ]),
    );
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(find.bySemanticsLabel('7 photos near 40.00, 12.00'), findsOneWidget);
    expect(find.bySemanticsLabel('99 photos near 45.00, 9.00'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });

  testWidgets('map distinguishes no GPS from an error and supports retry', (
    tester,
  ) async {
    var status = 500;
    final c = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient(
          (_) async => status == 200
              ? jsonResponse({'pos': null})
              : http.Response('', status),
        ),
      ),
    )..account = account;
    await tester.pumpWidget(
      MaterialApp(
        home: PhotoMapScreen(controller: c, onOpenArea: (_) {}),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('No geotagged photos yet.'), findsNothing);
    status = 200;
    await tester.tap(find.byTooltip('Retry'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No geotagged photos yet.'), findsOneWidget);
    expect(find.byType(FlutterMap), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    c.dispose();
  });
}
