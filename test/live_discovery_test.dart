import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/nextcloud_client.dart';

import 'app_test.dart' show MemoryStore;

void main() {
  test(
    'real Memories and Recognize support app-password discovery and all-photo map grids',
    () async {
      final client = NextcloudClient();
      addTearDown(client.close);
      final server = Uri.parse('http://127.0.0.1:8080');
      final owner = await client.authenticate(
        server,
        'ncloud-ci',
        const String.fromEnvironment('NEXTCLOUD_TEST_PASSWORD'),
      );
      final transport = http.Client();
      addTearDown(transport.close);
      final response = await transport.get(
        server.resolve('/ocs/v2.php/core/getapppassword?format=json'),
        headers: {
          'Authorization': owner.authorization,
          'OCS-APIRequest': 'true',
        },
      );
      expect(response.statusCode, 200);
      final token =
          (jsonDecode(response.body) as Map)['ocs']['data']['apppassword'];
      if (token is! String || token.isEmpty) {
        fail('The local fixture did not issue an app password.');
      }
      final account = await client.authenticate(server, owner.userId, token);
      final people = await client.memoryPeople(account);
      expect(
        people,
        isNotNull,
        reason: 'Recognize is installed in this fixture',
      );
      final position = await client.memoryMapPosition(account);
      expect(position, isNotNull);
      expect(position!.latitude, closeTo(45, 0.001));
      expect(position.longitude, closeTo(9, 0.001));
      final bounds = PhotoMapBounds(south: 44, north: 46, west: 8, east: 10);
      final clusters = await client.memoryMapClusters(
        account,
        bounds: bounds,
        zoom: 5,
      );
      expect(clusters, isNotEmpty);
      expect(clusters.fold<int>(0, (n, c) => n + c.count), 202);
      expect(clusters.any((c) => c.previewId != null), isTrue);
      final days = await client.memoryMapDays(account, [bounds]);
      expect(days.fold<int>(0, (n, day) => n + day.count), 202);
      final files = await client.memoryMapDayFiles(
        account,
        days.map((d) => d.id).toList(),
        [bounds],
      );
      expect(files, hasLength(202));
      expect(files.every((f) => f.pending), isTrue);
      expect(await client.preview(account, files.first), isNotEmpty);
      final outside = PhotoMapBounds(south: -10, north: 10, west: -20, east: 0);
      expect(
        await client.memoryMapClusters(account, bounds: outside, zoom: 5),
        isEmpty,
      );
      expect(await client.memoryMapDays(account, [outside]), isEmpty);
      final controller = AppController(store: MemoryStore(), client: client)
        ..account = account;
      addTearDown(controller.dispose);
      await controller.openMapArea([bounds]);
      expect(controller.error, isNull);
      expect(controller.items, hasLength(202));
      expect(controller.activePerson, isNull);
      await controller.openMapArea([outside]);
      expect(controller.error, isNull);
      expect(controller.items, isEmpty);
    },
    skip: !const bool.fromEnvironment('LIVE_DISCOVERY'),
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
