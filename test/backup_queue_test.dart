import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/cloud_backend.dart';
import 'package:ncloud/folder_sync.dart';
import 'package:ncloud/sync_schedule.dart';

import 'folder_sync_test.dart'
    show CloudFolders, DeviceFolders, TestSyncBackground;
import 'nextcloud_client_test.dart' show account;

class UnavailableScheduler implements BackupScheduler {
  int calls = 0;
  @override
  bool get supported => true;
  @override
  String? get notice => null;
  @override
  Future<void> cancel(String id) async {
    calls++;
    throw StateError('Scheduler unavailable');
  }

  @override
  Future<void> put(
    String id,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
  }) async {
    calls++;
    throw StateError('Scheduler unavailable');
  }
}

class FailingJournal extends SyncJournal {
  FailingJournal({required super.path});
  bool failSave = true;
  @override
  Future<void> save(FolderPair pair, {FolderPair? replacing}) {
    if (failSave) throw StateError('Disk failure');
    return super.save(pair, replacing: replacing);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SyncJournal journal;
  late FolderSyncController sync;
  late DeviceFolders device;
  late CloudFolders cloud;
  late UnavailableScheduler scheduler;

  Future<FolderPair> add(String name) async {
    await sync.add(name, DeviceFolder(name, name, name), [
      'Backup',
    ], wifiOnly: false);
    return sync.pairs.last;
  }

  setUp(() async {
    final parent = await Directory(
      '.dart_tool/backup-queue-tests',
    ).absolute.create(recursive: true);
    root = await parent.createTemp('run-');
    journal = SyncJournal(path: '${root.path}/pairs.sqlite3');
    cloud = CloudFolders();
    device = DeviceFolders(
      await Directory('${root.path}/source').create(),
      Directory('${root.path}/stage'),
    );
    scheduler = UnavailableScheduler();
    sync = FolderSyncController(
      client: cloud,
      account: () => account,
      journal: journal,
      access: device,
      scheduler: scheduler,
      android: true,
      backgroundService: TestSyncBackground(),
    );
    await sync.load();
  });

  tearDown(() async {
    await sync.disconnect();
    await journal.close();
    sync.dispose();
    await root.delete(recursive: true);
  });

  test(
    'manual pair saves and reopens without the background scheduler',
    () async {
      final pair = await add('Camera');
      await journal.close();
      final reopened = await journal.pair(pair.id);
      expect(reopened!.folder.token, pair.folder.token);
      expect(reopened.cloudRoot, ['Backup', 'Camera']);
      expect(scheduler.calls, 0);
      await sync.forget(pair);
      expect(await journal.pair(pair.id), isNull);
      expect(scheduler.calls, 0);
    },
  );

  test(
    'closing a worker journal preserves foreground results, saving and backup',
    () async {
      final pair = await add('Camera');
      final worker = SyncJournal(path: journal.path);
      try {
        await worker.writeState(pair.id, {
          'status': 'success',
          'transferred': 1,
        });
      } finally {
        await worker.close();
      }
      await sync.refreshResults();
      expect(sync.error, isNull);
      expect(sync.results[pair.id]?['status'], 'success');
      await add('Second');
      await device.put('photo.jpg', 'original');
      await sync.run(pair);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
    },
  );

  test(
    'save failure never reports success or publishes an unsaved pair',
    () async {
      await journal.close();
      journal = FailingJournal(path: '${root.path}/failure.sqlite3');
      sync.dispose();
      sync = FolderSyncController(
        client: cloud,
        account: () => account,
        journal: journal,
        access: device,
        android: true,
        backgroundService: TestSyncBackground(),
      );
      await sync.load();
      await expectLater(add('Camera'), throwsA(isA<CloudException>()));
      expect(sync.error, contains('Could not save'));
      expect(sync.error, isNot(contains('saved;')));
      expect(sync.pairs, isEmpty);
      expect(await journal.pairs(syncAccount(account)), isEmpty);
      (journal as FailingJournal).failSave = false;
      await add('Camera');
      expect(sync.error, isNull);
      expect(sync.pairs, hasLength(1));
    },
  );

  test(
    'back up all runs each pair once and continues after a failure',
    () async {
      await device.put('photo.jpg', 'original');
      final first = await add('First');
      final second = await add('Second');
      var attempts = 0;
      cloud.holdUpload = () async {
        if (attempts++ == 0) throw const CloudException('First failed');
      };
      final batch = sync.runAll();
      expect(sync.busy, isTrue);
      expect(sync.queuedIds, {first.id, second.id});
      await sync.runAll();
      await batch;
      expect(attempts, 2);
      expect(sync.results[first.id]!['status'], 'error');
      expect(sync.results[second.id]!['status'], 'success');
      expect(cloud.files.keys, ['Backup/Second/photo.jpg']);
      expect(sync.busy, isFalse);
      expect(sync.queuedIds, isEmpty);
    },
  );

  test(
    'pause all finishes the current file and does not start queued pairs',
    () async {
      await device.put('photo.jpg', 'original');
      final first = await add('First');
      final second = await add('Second');
      final started = Completer<void>(), release = Completer<void>();
      cloud.holdUpload = () async {
        started.complete();
        await release.future;
      };
      final batch = sync.runAll();
      await started.future;
      expect(sync.activeId, first.id);
      expect(sync.queuedIds, {second.id});
      final pause = sync.pauseAll();
      release.complete();
      await pause;
      await batch;
      expect(cloud.uploads, 1);
      expect(sync.results[first.id]!['status'], 'paused');
      expect(sync.results[second.id], isNull);
      expect(sync.queuedIds, isEmpty);
    },
  );

  test('individual backup never starts the other pair', () async {
    await device.put('photo.jpg', 'original');
    final first = await add('First');
    await add('Second');
    await sync.run(first);
    expect(cloud.files.keys, ['Backup/First/photo.jpg']);
    expect(cloud.uploads, 1);
  });

  test(
    'obsolete transfer configurations never become uploads without editing',
    () async {
      await device.put('photo.jpg', 'original');
      final saved = await add('Camera');
      final previous = FolderPair.fromJson(
        saved.toJson()..['mode'] = 'download',
      );
      sync.pairs = [previous];
      expect(previous.requiresSetup, isTrue);
      expect(FolderPair.fromJson(previous.toJson()).requiresSetup, isTrue);
      await sync.runAll();
      expect(cloud.uploads, 0);
      await sync.run(previous);
      expect(sync.error, contains('configure an upload backup'));
      expect(cloud.uploads, 0);
      await sync.add(
        previous.name,
        previous.folder,
        previous.remote,
        replacing: previous,
        wifiOnly: false,
      );
      expect(sync.pairs.single.requiresSetup, isFalse);
      await sync.runAll();
      expect(cloud.uploads, 1);
    },
  );
}
