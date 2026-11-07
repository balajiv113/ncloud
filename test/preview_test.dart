import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';

import 'app_test.dart' show MemoryStore;
import 'nextcloud_client_test.dart' show account;

CloudFile photo({
  String? id = '42',
  int size = 1024,
  DateTime? modified,
  String? etag,
}) => CloudFile(
  path: const ['Photos', 'Sun & sky.png'],
  name: 'Sun & sky.png',
  isDirectory: false,
  contentType: 'image/png',
  id: id,
  size: size,
  modified: modified,
  etag: etag,
);

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQqMgGAAGnAPzLMdOkAAAAAElFTkSuQmCC',
);

void main() {
  test('an in-flight preview cannot survive clearing the cache', () async {
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((_) {
          requested.complete();
          return response.future;
        }),
      ),
    )..account = account;
    addTearDown(controller.dispose);
    final pending = controller.preview(photo());
    final cancelled = expectLater(pending, throwsA(isA<PreviewCancelled>()));
    await requested.future;
    await controller.clearCache();
    response.complete(http.Response.bytes(png, 200));
    await cancelled;
    expect(controller.cachedPreview(photo()), isNull);
  });

  test('an in-flight preview is discarded when its account changes', () async {
    final response = Completer<http.Response>();
    final requested = Completer<void>();
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((_) {
          requested.complete();
          return response.future;
        }),
      ),
    )..account = account;
    addTearDown(controller.dispose);
    final pending = controller.preview(photo());
    final cancelled = expectLater(pending, throwsA(isA<PreviewCancelled>()));
    await requested.future;
    controller.account = null;
    response.complete(http.Response.bytes(png, 200));
    await cancelled;
    controller.account = account;
    expect(controller.cachedPreview(photo()), isNull);
  });

  test(
    'small preview requests retain authentication and subfolder paths',
    () async {
      final client = NextcloudClient(
        transport: MockClient((request) async {
          expect(request.url.path, '/nextcloud/index.php/core/preview');
          expect(request.url.queryParameters['x'], '384');
          expect(request.url.queryParameters['y'], '384');
          expect(request.headers['Authorization'], account.authorization);
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(png, 200);
        }),
      );
      addTearDown(client.close);
      expect(await client.preview(account, photo()), png);
    },
  );

  test('server overload is retried once, then its error is surfaced', () async {
    var calls = 0;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        calls++;
        return http.Response('', 503);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.preview(account, photo()),
      throwsA(isA<CloudException>()),
    );
    expect(calls, 2);
  });

  test('missing previews never download small raster originals', () async {
    var calls = 0;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        calls++;
        expect(request.url.path, endsWith('/core/preview'));
        return http.Response('', 404);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.preview(account, photo()),
      throwsA(isA<CloudException>()),
    );
    expect(calls, 1);
  });

  test('large originals are not downloaded on missing preview', () async {
    var calls = 0;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        calls++;
        return http.Response('', 404);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.preview(account, photo(size: 3000000)),
      throwsA(isA<CloudException>()),
    );
    expect(calls, 1);
  });

  test('missing file IDs never fetch an original automatically', () async {
    var calls = 0;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        calls++;
        return http.Response.bytes(png, 200);
      }),
    );
    addTearDown(client.close);
    await expectLater(
      client.preview(account, photo(id: null)),
      throwsA(isA<CloudException>()),
    );
    expect(calls, 0);
  });

  test('preview transfers never exceed four simultaneous requests', () async {
    final gates = <Completer<void>>[];
    var active = 0;
    var maximum = 0;
    final client = NextcloudClient(
      transport: MockClient((request) async {
        final gate = Completer<void>();
        gates.add(gate);
        active++;
        if (active > maximum) maximum = active;
        await gate.future;
        active--;
        return http.Response.bytes(png, 200);
      }),
    );
    addTearDown(client.close);
    Future<void> waitForGates(int count) async {
      for (var i = 0; i < 200 && gates.length < count; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }

    final pending = List.generate(
      8,
      (i) => client.preview(account, photo(id: '$i')),
    );
    await waitForGates(4);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(gates, hasLength(4));
    for (final gate in gates.toList()) {
      gate.complete();
    }
    await waitForGates(8);
    expect(gates, hasLength(8));
    for (final gate in gates.skip(4)) {
      gate.complete();
    }
    await Future.wait(pending);
    expect(maximum, 4);
  });

  test(
    'cache deduplicates, retries failures and separates viewer revisions',
    () async {
      var calls = 0;
      final client = NextcloudClient(
        transport: MockClient((request) async {
          calls++;
          return calls == 1
              ? http.Response('', 401)
              : http.Response.bytes(png, 200);
        }),
      );
      final controller = AppController(store: MemoryStore(), client: client)
        ..account = account;
      addTearDown(controller.dispose);
      final first = controller.preview(photo());
      expect(identical(first, controller.preview(photo())), isTrue);
      await expectLater(first, throwsA(isA<CloudException>()));
      expect(controller.cachedPreview(photo()), isNull);
      expect(await controller.preview(photo()), png);
      expect(await controller.preview(photo()), png);
      expect(controller.cachedPreview(photo()), png);
      expect(controller.previewCurrent(photo()), isTrue);
      expect(calls, 2);
      await controller.preview(photo(), size: 1280);
      final edited = photo(modified: DateTime.utc(2026, 11, 6));
      expect(controller.previewCurrent(edited), isFalse);
      expect(
        controller.cachedPreview(edited),
        png,
        reason: 'the older revision stays visible while the edit loads',
      );
      await controller.preview(edited);
      expect(calls, 4);
    },
  );

  test('cache remains bounded by entry count and encoded bytes', () async {
    var calls = 0;
    final data = Uint8List(7 * 1024 * 1024 + 512 * 1024);
    final client = NextcloudClient(
      transport: MockClient((request) async {
        calls++;
        return http.Response.bytes(data, 200);
      }),
    );
    final controller = AppController(store: MemoryStore(), client: client)
      ..account = account;
    addTearDown(controller.dispose);
    for (var i = 0; i < 9; i++) {
      await controller.preview(photo(id: '$i'));
    }
    expect(controller.cachedPreview(photo(id: '8')), isNotNull);
    expect(controller.cachedPreview(photo(id: '0')), isNull);
    await controller.preview(photo(id: '0'));
    expect(calls, 10);
  });
}
