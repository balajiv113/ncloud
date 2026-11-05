import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/library_screen.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/nextcloud_client.dart';
import 'package:ncloud/people_bubble.dart';

import 'app_test.dart' show MemoryStore;
import 'discovery_test.dart' show jsonResponse;
import 'nextcloud_client_test.dart' show account, multistatus;
import 'preview_test.dart' show photo, png;

const samplePerson = RecognizedPerson(
  id: 12,
  name: 'Sample',
  count: 3001,
  cover: 41,
  coverEtag: 'new',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'people ignore photo-source changes but discard signed-out responses',
    () async {
      final responses = <Completer<http.Response>>[];
      final dir = await Directory.systemTemp.createTemp('ncloud-signout-');
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (_) async => dir.path);
      addTearDown(() async {
        messenger.setMockMethodCallHandler(channel, null);
        await dir.delete(recursive: true);
      });
      var requested = Completer<void>();
      final c = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((_) {
            final response = Completer<http.Response>();
            responses.add(response);
            requested.complete();
            return response.future;
          }),
        ),
      )..account = account;
      addTearDown(c.dispose);
      final first = c.loadPeople();
      await requested.future;
      c.account = account.withPhotoRoot(['Other photos']);
      responses.single.complete(jsonResponse([samplePerson.toJson()]));
      await first;
      expect(c.people.single.id, 12);
      expect(c.loadingPeople, isFalse);
      requested = Completer<void>();
      final second = c.loadPeople(refresh: true);
      await requested.future;
      await c.signOut();
      responses.last.complete(jsonResponse([samplePerson.toJson()]));
      await second;
      expect(c.people, isEmpty);
      expect(c.peopleError, isNull);
      expect(c.loadingPeople, isFalse);
    },
  );

  test('people refresh keeps cached groups on failure and can retry', () async {
    var status = 200;
    var calls = 0;
    final c = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((_) async {
          calls++;
          return status == 200
              ? jsonResponse([samplePerson.toJson()])
              : http.Response('', status);
        }),
      ),
    )..account = account;
    addTearDown(c.dispose);
    await c.loadPeople();
    expect(c.people.single.id, 12);
    expect(c.peopleAvailable, isTrue);
    await c.loadPeople();
    expect(calls, 1);
    status = 401;
    await c.loadPeople(refresh: true);
    expect(c.people.single.id, 12);
    expect(c.peopleError, isNotNull);
    expect(c.loadingPeople, isFalse);
    status = 200;
    await c.loadPeople(refresh: true);
    expect(c.peopleError, isNull);
    expect(calls, 3);
  });

  test('saved people appear before the server responds', () async {
    final dir = await Directory.systemTemp.createTemp('ncloud-people-');
    addTearDown(() => dir.delete(recursive: true));
    final cache = LocalCache(() async => dir);
    final key = 'people-v1|${account.server}|${account.userId}';
    await cache.writeDocument(key, {
      'people': [
        {'id': 5, 'name': 'Small', 'count': 1},
        {'id': 6, 'name': 'Large', 'count': 10},
      ],
    });
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final c = AppController(
      store: MemoryStore(),
      cache: cache,
      client: NextcloudClient(
        transport: MockClient((_) {
          requested.complete();
          return response.future;
        }),
      ),
    )..account = account;
    addTearDown(c.dispose);
    final loading = c.loadPeople();
    await requested.future;
    expect(c.loadingPeople, isTrue);
    expect(c.people.map((p) => p.count), [10, 1]);
    response.complete(jsonResponse([samplePerson.toJson()]));
    await loading;
    expect(c.people.single.id, 12);

    await cache.writeDocument(key, {'people': 'damaged'});
    c.people = [];
    final other = AppController(
      store: MemoryStore(),
      cache: cache,
      client: NextcloudClient(
        transport: MockClient(
          (_) async => jsonResponse([samplePerson.toJson()]),
        ),
      ),
    )..account = account;
    addTearDown(other.dispose);
    await other.loadPeople();
    expect(other.people.single.id, 12);
    expect(other.notice, contains('damaged'));
    expect(other.peopleError, isNull);
  });

  test('face cache is shown before a deduplicated revision update', () async {
    final dir = await Directory.systemTemp.createTemp('ncloud-face-');
    addTearDown(() => dir.delete(recursive: true));
    final cache = LocalCache(() async => dir);
    final key = 'face-v1|${account.server}|${account.userId}|12';
    await cache.writeThumbnail(key, png, version: '41|old');
    final response = Completer<http.Response>();
    var calls = 0;
    final c = AppController(
      store: MemoryStore(),
      cache: cache,
      client: NextcloudClient(
        transport: MockClient((_) {
          calls++;
          return response.future;
        }),
      ),
    )..account = account;
    addTearDown(c.dispose);
    expect(await c.restorePersonPreview(samplePerson), png);
    expect(calls, 0);
    final first = c.personPreview(samplePerson);
    final second = c.personPreview(samplePerson);
    response.complete(http.Response.bytes(png, 200));
    await Future.wait([first, second]);
    expect(calls, 1);
    expect((await cache.readThumbnail(key))!.version, '41|new');
    expect(await c.personPreview(samplePerson), png);
    expect(calls, 1);
  });

  test(
    'person filters survive paging, scrubbing and cached navigation',
    () async {
      final requests = <http.Request>[];
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  requests.add(request);
                  if (request.method == 'PROPFIND') {
                    return http.Response(multistatus(''), 207);
                  }
                  expect(request.method, 'GET');
                  final person = request.url.queryParameters['recognize'];
                  expect(
                    person,
                    anyOf('${account.userId}/12', '${account.userId}/13'),
                  );
                  final other = person!.endsWith('/13');
                  if (request.url.path.endsWith('/days')) {
                    return jsonResponse(
                      other
                          ? [
                              {'dayid': 21000, 'count': 1},
                            ]
                          : [
                              {'dayid': 21000, 'count': 1500},
                              {'dayid': 20999, 'count': 1},
                              {'dayid': 20998, 'count': 1500},
                            ],
                    );
                  }
                  final days = request.url.pathSegments.last
                      .split(',')
                      .map(int.parse);
                  return jsonResponse([
                    for (final day in days)
                      for (
                        var i = 0;
                        i < (other || day == 20999 ? 1 : 1500);
                        i++
                      )
                        {
                          'fileid': other ? 13 : day * 10000 + i,
                          'dayid': day,
                          'basename': 'person-photo.jpg',
                          'etag': 'rev',
                        },
                  ]);
                }),
              ),
            )
            ..account = account
            ..memoriesAvailable = true;
      addTearDown(c.dispose);
      c.fileStore.putAll([photo()]);
      final opening = c.openPerson(samplePerson);
      expect(c.items, isEmpty);
      expect(c.albumHome, isFalse);
      await opening;
      expect(c.items, hasLength(1500));
      expect(c.items.every((f) => f.pending), isTrue);
      c.ensureDays([20998]);
      for (var i = 0; i < 100 && c.fetchingDays; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(c.dayLoaded(20998), isTrue);
      await c.loadNextPage();
      expect(c.items, hasLength(3001));
      final calls = requests.length;
      await c.openPerson(const RecognizedPerson(id: 13, name: '', count: 1));
      expect(c.items.single.id, '13');
      expect(c.activePerson!.label, 'Unnamed person');
      await c.openPerson(samplePerson);
      expect(c.items, hasLength(3001));
      expect(requests.length, calls + 2);
      await c.selectTab(1);
      expect(c.activePerson, isNull);
    },
  );

  testWidgets(
    'round People bubbles follow Smart albums and open the shared grid',
    (tester) async {
      final c =
          AppController(
              store: MemoryStore(),
              client: NextcloudClient(
                transport: MockClient((request) async {
                  if (request.url.path.endsWith('/preview')) {
                    return http.Response.bytes(png, 200);
                  }
                  if (request.url.path.endsWith('/days')) {
                    return jsonResponse([
                      {'dayid': 21000, 'count': 1},
                    ]);
                  }
                  if (request.url.path.contains('/days/')) {
                    return jsonResponse([
                      {
                        'fileid': 42,
                        'dayid': 21000,
                        'basename': 'portrait.jpg',
                      },
                    ]);
                  }
                  return http.Response('', 404);
                }),
              ),
            )
            ..account = account
            ..tab = 4
            ..memoriesAvailable = true
            ..people = [
              const RecognizedPerson(id: 12, name: 'Most', count: 30),
              const RecognizedPerson(id: 13, name: 'Next', count: 20),
            ];
      await tester.pumpWidget(
        MaterialApp(
          home: ListenableBuilder(
            listenable: c,
            builder: (_, _) => LibraryScreen(controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(find.text('People')).dy,
        greaterThan(tester.getTopLeft(find.text('Smart albums')).dy),
      );
      expect(
        find.descendant(
          of: find.byType(PeopleBubble),
          matching: find.byType(ClipOval),
        ),
        findsNWidgets(2),
      );
      expect(
        tester.getTopLeft(find.text('Most')).dx,
        lessThan(tester.getTopLeft(find.text('Next')).dx),
      );
      await tester.tap(find.byKey(const ValueKey('View all People')));
      await tester.pumpAndSettle();
      expect(find.text('Recognize · most photos first'), findsOneWidget);
      await tester.tap(find.bySemanticsLabel('Most, 30 photos'));
      await tester.pumpAndSettle();
      expect(c.activePerson!.id, 12);
      expect(find.text('Most'), findsOneWidget);
      expect(find.bySemanticsLabel('portrait.jpg'), findsOneWidget);
      expect(find.byTooltip('Album actions'), findsNothing);
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.text('Recognize · most photos first'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      c.dispose();
    },
  );
}
