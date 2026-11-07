import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/cloud_backend.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;

http.Response _approval() => http.Response(
  jsonEncode({
    'login': 'https://cloud.example/login/approve',
    'poll': {
      'endpoint': 'https://cloud.example/login/poll',
      'token': 'one-time-token',
    },
  }),
  200,
);

http.Response _credentials() => http.Response(
  jsonEncode({
    'server': 'https://cloud.example',
    'loginName': 'alice@example.com',
    'appPassword': 'issued-app-password',
  }),
  200,
);

http.Response _user() => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'status': 'ok'},
      'data': {'id': 'alice', 'display-name': 'Alice'},
    },
  }),
  200,
);

void main() {
  test(
    'one-time credentials survive an OCS authentication lag inside HTTP 200',
    () async {
      var exchanges = 0;
      var verifications = 0;
      final client = NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.endsWith('/login/v2')) return _approval();
          if (request.url.path.endsWith('/login/poll')) {
            exchanges++;
            return _credentials();
          }
          if (++verifications == 1) {
            return http.Response(
              jsonEncode({
                'ocs': {
                  'meta': {
                    'status': 'failure',
                    'statuscode': '997',
                    'message': 'Unauthorised',
                  },
                  'data': [],
                },
              }),
              200,
            );
          }
          return _user();
        }),
      );
      addTearDown(client.close);
      final server = Uri.parse('https://cloud.example');
      final flow = await client.startLogin(server);
      await expectLater(
        client.pollLogin(server, flow),
        throwsA(
          isA<CloudException>()
              .having((e) => e.statusCode, 'status', 401)
              .having((e) => e.retryable, 'retryable', true),
        ),
      );
      expect((await client.pollLogin(server, flow))?.userId, 'alice');
      expect(exchanges, 1);
      expect(verifications, 2);
    },
  );

  testWidgets('browser polling waits for app resume without failing sign-in', (
    tester,
  ) async {
    var polls = 0;
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.endsWith('/login/v2')) return _approval();
          if (request.url.path.endsWith('/login/poll')) {
            polls++;
            return _credentials();
          }
          if (request.url.path.endsWith('/cloud/user')) return _user();
          if (request.url.path.contains('/apps/memories/')) {
            return http.Response('', 404);
          }
          return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
        }),
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final login = controller.browserLogin('https://cloud.example', (_) async {
      controller.setBrowsingActive(false);
      return true;
    });
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));
    expect(polls, 0);
    expect(controller.signingIn, isTrue);
    expect(controller.error, isNull);
    controller.setBrowsingActive(true);
    await tester.pump();
    await login;
    expect(polls, 1);
    expect(controller.connected, isTrue);
    expect(controller.error, isNull);
  });

  testWidgets('cancel wakes a login waiting for browser return', (
    tester,
  ) async {
    final requests = <String>[];
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((request) async {
          requests.add(request.url.path);
          return _approval();
        }),
      ),
    );
    addTearDown(controller.dispose);
    final login = controller.browserLogin('https://cloud.example', (_) async {
      controller.setBrowsingActive(false);
      return true;
    });
    await tester.pump();
    controller.cancelLogin();
    await tester.pump();
    await login;
    expect(controller.signingIn, isFalse);
    expect(controller.connected, isFalse);
    expect(controller.error, isNull);
    expect(requests, ['/index.php/login/v2']);
  });

  testWidgets('an interrupted background poll retries after browser return', (
    tester,
  ) async {
    final poll = Completer<http.Response>();
    var polls = 0;
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.endsWith('/login/v2')) return _approval();
          if (request.url.path.endsWith('/login/poll')) {
            return ++polls == 1 ? poll.future : _credentials();
          }
          if (request.url.path.endsWith('/cloud/user')) return _user();
          if (request.url.path.contains('/apps/memories/')) {
            return http.Response('', 404);
          }
          return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
        }),
      ),
    );
    addTearDown(controller.dispose);
    await controller.initialize();
    final login = controller.browserLogin(
      'https://cloud.example',
      (_) async => true,
    );
    await tester.pump();
    expect(polls, 1);
    controller.setBrowsingActive(false);
    poll.complete(http.Response('', 503));
    await tester.pump();
    await tester.pump(const Duration(minutes: 1));
    expect(polls, 1);
    expect(controller.signingIn, isTrue);
    expect(controller.error, isNull);
    controller.setBrowsingActive(true);
    await tester.pump();
    await login;
    expect(polls, 2);
    expect(controller.connected, isTrue);
  });

  test(
    'one-time browser exchange survives transient verification failure',
    () async {
      var exchanges = 0;
      var verifications = 0;
      final client = NextcloudClient(
        transport: MockClient((request) async {
          if (request.url.path.endsWith('/login/v2')) return _approval();
          if (request.url.path.endsWith('/login/poll')) {
            exchanges++;
            return exchanges == 1 ? _credentials() : http.Response('', 404);
          }
          if (request.url.path.endsWith('/cloud/user')) {
            verifications++;
            return verifications == 1 ? http.Response('', 503) : _user();
          }
          return http.Response('', 404);
        }),
      );
      addTearDown(client.close);
      final server = Uri.parse('https://cloud.example');
      final flow = await client.startLogin(server);
      await expectLater(
        client.pollLogin(server, flow),
        throwsA(
          isA<CloudException>().having((e) => e.retryable, 'retryable', true),
        ),
      );
      final account = await client.pollLogin(server, flow);
      expect(account?.userId, 'alice');
      expect(exchanges, 1);
      expect(verifications, 2);
    },
  );

  test(
    'browser login retries temporary polling failures without reopening browser',
    () async {
      var polls = 0;
      var launches = 0;
      final store = MemoryStore();
      final controller = AppController(
        store: store,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/login/v2')) return _approval();
            if (request.url.path.endsWith('/login/poll')) {
              return ++polls == 1 ? http.Response('', 503) : _credentials();
            }
            if (request.url.path.endsWith('/cloud/user')) return _user();
            if (request.url.path.contains('/apps/memories/')) {
              return http.Response('', 404);
            }
            return http.Response('<d:multistatus xmlns:d="DAV:"/>', 207);
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.browserLogin('https://cloud.example', (_) async {
        launches++;
        return true;
      });
      expect(controller.connected, true);
      expect(controller.error, isNull);
      expect(store.value, isNotNull);
      expect(launches, 1);
      expect(polls, 2);
    },
  );

  test(
    'cancelling while the browser opens never polls or saves an account',
    () async {
      var polls = 0;
      final opened = Completer<bool>();
      final opening = Completer<void>();
      final store = MemoryStore();
      final controller = AppController(
        store: store,
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/login/v2')) return _approval();
            polls++;
            return _credentials();
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      final login = controller.browserLogin('https://cloud.example', (_) {
        opening.complete();
        return opened.future;
      });
      await opening.future;
      controller.cancelLogin();
      opened.complete(true);
      await login;
      expect(polls, 0);
      expect(controller.connected, false);
      expect(store.value, isNull);
    },
  );

  test(
    'permanent polling rejection does not retry or hide the error',
    () async {
      var polls = 0;
      final controller = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((request) async {
            if (request.url.path.endsWith('/login/v2')) return _approval();
            polls++;
            return http.Response('', 403);
          }),
        ),
      );
      addTearDown(controller.dispose);
      await controller.initialize();
      await controller.browserLogin('https://cloud.example', (_) async => true);
      expect(controller.connected, false);
      expect(controller.error, contains('permission'));
      expect(controller.signingIn, false);
      expect(polls, 1);
    },
  );
}
