import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/nextcloud_client.dart';
import 'package:ncloud/warm_start_screen.dart';

import 'app_test.dart' show MemoryStore;
import 'memories_test.dart' show indexedTransport;
import 'nextcloud_client_test.dart' show account;
import 'preview_test.dart' show png;
import 'timeline_speed_test.dart' show multipreviewBody;

MockClient warmTransport(
  List<http.Request> calls, {
  Future<void>? indexGate,
  bool failIndex = false,
}) {
  final indexed = indexedTransport(calls);
  return MockClient((request) async {
    if (request.url.path.endsWith('/days')) {
      if (indexGate != null) await indexGate;
      if (failIndex) return http.Response('', 500);
    }
    if (request.url.path.endsWith('/multipreview')) {
      final files = (jsonDecode(request.body) as Map)['files'] as List;
      return http.Response.bytes(
        multipreviewBody(files.map((f) => (f as Map)['reqid'] as String)),
        200,
      );
    }
    if (request.url.path.endsWith('/preview')) {
      return http.Response.bytes(png, 200);
    }
    final forwarded = http.Request(request.method, request.url)
      ..headers.addAll(request.headers)
      ..bodyBytes = request.bodyBytes;
    return http.Response.fromStream(await indexed.send(forwarded));
  });
}

void main() {
  late Directory root;
  late LocalCache cache;
  final key = 'warm-v2|${account.server}|${account.userId}';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('ncloud-warm-test');
    cache = LocalCache(() async => root);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'existing sessions prepare recent years despite the old warm marker',
    () async {
      await cache.writeDocument('warm-v1|${account.server}|${account.userId}', {
        'at': 'old-attempt',
      });
      final calls = <http.Request>[];
      final gate = Completer<void>();
      final c = AppController(
        store: MemoryStore()..value = account.encode(),
        cache: cache,
        client: NextcloudClient(
          transport: warmTransport(calls, indexGate: gate.future),
        ),
        pathlessTimeline: true,
      );
      final initialization = c.initialize();
      for (
        var i = 0;
        i < 100 && !calls.any((r) => r.url.path.endsWith('/days'));
        i++
      ) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        if (c.warming) break;
      }
      expect(c.warming, isTrue);
      expect(await cache.readDocument(key), isNull);
      gate.complete();
      await initialization;
      expect(c.error, isNull);
      expect(c.warming, isFalse);
      expect(c.warmTotal, 1800);
      expect(c.warmDone, 1800);
      expect(c.items, hasLength(1800));
      expect(c.cachedPreview(c.items.first), isNotNull);
      expect(calls.where((r) => r.method == 'SEARCH'), isEmpty);
      expect((await cache.readDocument(key))?['complete'], isTrue);
      c.dispose();

      final restored = AppController(
        store: MemoryStore()..value = account.encode(),
        cache: cache,
        client: NextcloudClient(transport: warmTransport([])),
        pathlessTimeline: true,
      );
      await restored.initialize();
      expect(restored.error, isNull);
      expect(restored.items, hasLength(1800));
      expect(
        restored.warmPhase,
        0,
        reason: 'successful preparation is not repeated',
      );
      restored.dispose();
    },
  );

  test('failed preparation does not save a completion marker', () async {
    final c = AppController(
      store: MemoryStore()..value = account.encode(),
      cache: cache,
      client: NextcloudClient(transport: warmTransport([], failIndex: true)),
      pathlessTimeline: true,
    );
    await c.initialize();
    expect(c.warming, isFalse);
    expect(c.error, isNotNull);
    expect(await cache.readDocument(key), isNull);
    c.dispose();
  });

  testWidgets('preparation is skippable without cancelling metadata loading', (
    tester,
  ) async {
    final gate = Completer<void>();
    final c = AppController(
      store: MemoryStore()..value = account.encode(),
      client: NextcloudClient(
        transport: warmTransport([], indexGate: gate.future),
      ),
      pathlessTimeline: true,
    );
    await tester.pumpWidget(NcloudApp(controller: c));
    await tester.pump();
    expect(find.byType(WarmStartScreen), findsOneWidget);
    await tester.tap(find.text('Start browsing now'));
    await tester.pump();
    expect(find.byType(WarmStartScreen), findsNothing);
    gate.complete();
    await tester.pumpAndSettle();
    expect(c.items, hasLength(1800));
    expect(c.warmDone, 1800);
    expect(c.error, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'restored login shows preparation and a slow server cannot hold it past 30 seconds',
    (tester) async {
      final gate = Completer<void>();
      final c = AppController(
        store: MemoryStore()..value = account.encode(),
        client: NextcloudClient(
          transport: warmTransport([], indexGate: gate.future),
        ),
        pathlessTimeline: true,
      );
      await tester.pumpWidget(NcloudApp(controller: c));
      await tester.pump();
      expect(find.byType(WarmStartScreen), findsOneWidget);
      expect(find.text('Preparing your library'), findsOneWidget);
      await tester.pump(const Duration(seconds: 31));
      expect(find.byType(WarmStartScreen), findsNothing);
      gate.complete();
      await tester.pumpAndSettle();
      expect(c.items, hasLength(1800));
      expect(c.error, isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
