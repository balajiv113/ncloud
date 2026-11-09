import 'package:ncloud/features/backup/background/backup_scheduler.dart';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:ncloud/features/backup/model/backup_schedule.dart';

import 'app_test.dart' show MemoryStore;
import 'features/backup/backup_controller_test.dart'
    show CloudFolders, DeviceFolders, TestSyncBackground;
import 'nextcloud_client_test.dart' show account;
import 'support/sample_library.dart';

class _KeychainFailure extends MemoryStore {
  @override
  Future<void> clear() async => throw StateError('keychain unavailable');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SyncJournal journal;
  late DeviceFolders device;
  late LocalCache cache;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('ncloud-wipe-');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => root.path,
    );
    journal = SyncJournal(path: '${root.path}/journal.sqlite3');
    device = DeviceFolders(
      await Directory('${root.path}/source').create(),
      Directory('${root.path}/stage'),
    );
    cache = LocalCache(() async => Directory('${root.path}/cache'));
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await cache.close();
    await journal.close();
    await root.delete(recursive: true);
  });

  Future<AppController> signedIn(MemoryStore store) async {
    late AppController controller;
    final sync = BackupController(
      client: CloudFolders(),
      account: () => controller.account,
      journal: journal,
      access: device,
      scheduler: _NoScheduler(),
      android: true,
      backgroundService: TestSyncBackground(),
    );
    controller = AppController(
      store: store,
      client: SampleLibrary(),
      cache: cache,
      backupController: sync,
    )..account = account.withPhotoRoot(['Photos']);
    addTearDown(controller.dispose);
    await sync.load();
    await sync.add('Camera', const DeviceFolder('t', 'Camera', 'camera'), [
      'Backup',
    ], wifiOnly: false);
    await device.stage();
    await cache.writeThumbnail('k', Uint8List(10), version: 'v');
    return controller;
  }

  test(
    'signing out wipes backup records, staged files and cached data',
    () async {
      final store = MemoryStore()..value = 'saved';
      final controller = await signedIn(store);
      expect(await journal.pairs(syncAccount(account)), isNotEmpty);
      await controller.signOut();
      expect(controller.error, isNull);
      expect(store.value, isNull);
      expect(await journal.pairs(syncAccount(account)), isEmpty);
      expect(device.clears, 1);
      expect(device.staging.existsSync(), isFalse);
      expect(await cache.readThumbnail('k'), isNull);
    },
  );

  test('a step that fails does not stop the rest of the wipe', () async {
    final controller = await signedIn(_KeychainFailure());
    await controller.signOut();
    expect(controller.error, contains('Could not completely clear'));
    expect(await journal.pairs(syncAccount(account)), isEmpty);
    expect(device.clears, 1);
    expect(await cache.readThumbnail('k'), isNull);
  });
}

class _NoScheduler implements BackupScheduler {
  @override
  bool get supported => false;
  @override
  String? get notice => null;
  @override
  Future<void> cancel(String id) async {}
  @override
  Future<void> put(
    String id,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
  }) async {}
}
