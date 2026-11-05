import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/change_monitor.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'nextcloud_client_test.dart' show account;

http.Response capabilities([String? endpoint]) => http.Response(
  jsonEncode({
    'ocs': {
      'meta': {'statuscode': 100},
      'data': {
        'capabilities': {
          if (endpoint != null)
            'notify_push': {
              'endpoints': {'websocket': endpoint},
            },
        },
      },
    },
  }),
  200,
);

void main() {
  testWidgets('idle and background stop every monitor timer and request', (
    tester,
  ) async {
    var checks = 0;
    var discoveries = 0;
    final states = <bool>[];
    final client = NextcloudClient(
      transport: MockClient((_) async {
        discoveries++;
        return capabilities();
      }),
    );
    final monitor = ChangeMonitor(
      client: client,
      account: account,
      check: (_, _) async {
        checks++;
        return false;
      },
      onActive: states.add,
      onError: (e) => fail('$e'),
      idleAfter: const Duration(minutes: 5),
    );
    monitor.activity();
    await tester.pump();
    expect(checks, 1);
    await tester.pump(const Duration(minutes: 2));
    expect(checks, 2);
    await tester.pump(const Duration(minutes: 3));
    final before = checks;
    expect(states.last, isFalse);
    await tester.pump(const Duration(hours: 2));
    expect(checks, before, reason: 'idle must have zero periodic network work');
    monitor.activity();
    await tester.pump();
    expect(checks, before + 1);
    expect(discoveries, 1);
    monitor.setForeground(false);
    await tester.pump(const Duration(hours: 1));
    expect(checks, before + 1);
    monitor.setForeground(true);
    await tester.pump();
    expect(checks, before + 2);
    monitor.dispose();
    client.close();
  });

  test(
    'push endpoint rejects credential forwarding to another origin',
    () async {
      for (final endpoint in [
        'wss://untrusted.example/push/ws',
        'ws://cloud.example/nextcloud/push/ws',
        'wss://user:password@cloud.example/push/ws',
      ]) {
        final client = NextcloudClient(
          transport: MockClient((_) async => capabilities(endpoint)),
        );
        addTearDown(client.close);
        await expectLater(
          client.pushEndpoint(account),
          throwsA(isA<CloudException>()),
        );
      }
    },
  );

  test(
    'optional push absence is distinct from authorization failure',
    () async {
      var status = 404;
      final client = NextcloudClient(
        transport: MockClient((_) async => http.Response('', status)),
      );
      addTearDown(client.close);
      expect(await client.pushEndpoint(account), isNull);
      status = 401;
      await expectLater(
        client.pushEndpoint(account),
        throwsA(isA<CloudException>()),
      );
    },
  );

  test(
    'push authenticates, subscribes to file IDs and coalesces updates',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      WebSocket? peer;
      final received = <String>[];
      final subscribed = Completer<void>();
      final closed = Completer<void>();
      final subscription = server.listen((request) async {
        peer = await WebSocketTransformer.upgrade(request);
        peer!.listen((event) {
          received.add(event as String);
          if (received.length == 2) peer!.add('authenticated');
          if (event == 'listen notify_file_id') {
            peer!.add('notify_file_id [12,13]');
            peer!.add('notify_file_id [13,14]');
            subscribed.complete();
          }
        }, onDone: () => closed.complete());
      });
      final done = Completer<Set<String>?>();
      final client = NextcloudClient(
        transport: MockClient(
          (_) async => capabilities(
            '${account.server.toString().replaceFirst('https:', 'wss:')}/push/ws',
          ),
        ),
      );
      final monitor = ChangeMonitor(
        client: client,
        account: account,
        check: (ids, pushed) async {
          if (pushed && !done.isCompleted) done.complete(ids);
          return false;
        },
        onActive: (_) {},
        onError: (e) => fail('$e'),
        connect: (_) => WebSocket.connect('ws://127.0.0.1:${server.port}'),
      );
      addTearDown(() async {
        monitor.dispose();
        client.close();
        await peer?.close();
        await subscription.cancel();
        await server.close(force: true);
      });
      monitor.activity();
      await subscribed.future.timeout(const Duration(seconds: 5));
      expect(await done.future.timeout(const Duration(seconds: 5)), {
        '12',
        '13',
        '14',
      });
      expect(received, [
        account.loginName,
        account.appPassword,
        'listen notify_file_id',
      ]);
      monitor.setForeground(false);
      await closed.future.timeout(const Duration(seconds: 5));
    },
  );
}
