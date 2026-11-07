import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/folder_sync_screen.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/folder_sync.dart';
import 'package:ncloud/features/backup/headless_backup.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/features/backup/sync_run_lock.dart';
import 'package:ncloud/features/backup/sync_schedule.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../app_test.dart' show MemoryStore;
import 'folder_sync_test.dart'
    show CloudFolders, DeviceFolders, TestSyncBackground;
import '../../nextcloud_client_test.dart' show account;

class RecordingScheduler implements BackupScheduler {
  final jobs = <String, String>{};
  final cancelled = <String>[];
  bool fail = false;
  @override
  bool get supported => true;
  @override
  String? get notice => null;
  @override
  Future<void> put(
    String pairId,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
  }) async {
    if (fail) throw PlatformException(code: 'schedule_denied');
    jobs[pairId] = revision;
  }

  @override
  Future<void> cancel(String pairId) async {
    cancelled.add(pairId);
    jobs.remove(pairId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final created = DateTime(2026, 1, 1);
  late DateTime now;
  late Directory root;
  late SyncJournal journal;
  late DeviceFolders device;
  late CloudFolders cloud;
  late RecordingScheduler scheduler;
  late FolderSyncController ui;
  late TestSyncBackground background;
  final lock = InProcessSyncRunLock();

  BackupSchedule schedule() =>
      BackupSchedule(created: created, hour: 10, minute: 20);

  FolderSyncController controller() => FolderSyncController(
    client: cloud,
    account: () => account,
    access: device,
    journal: journal,
    scheduler: scheduler,
    runLock: lock,
    android: true,
    backgroundService: background,
  );

  Future<FolderPair> add({BackupSchedule? value, FolderPair? replacing}) async {
    await ui.load();
    await ui.add(
      'Scheduled',
      const DeviceFolder('grant', 'Selected', 'folder-id'),
      ['Backup'],
      schedule: value ?? schedule(),
      replacing: replacing,
    );
    return ui.pairs.single;
  }

  ScheduledBackupRunner runner({
    Account? credentials,
    bool loggedOut = false,
    void Function()? close,
    Duration budget = const Duration(minutes: 8),
  }) => ScheduledBackupRunner(
    journal: journal,
    lock: lock,
    readAccount: () async => loggedOut ? null : credentials ?? account,
    client: cloud,
    closeClient: close ?? () {},
    access: device,
    clock: () => now,
    budget: budget,
  );

  setUp(() async {
    final parent = await Directory(
      '.dart_tool/scheduled-backup-tests',
    ).absolute.create(recursive: true);
    root = await parent.createTemp('run-');
    journal = SyncJournal(path: '${root.path}/journal.sqlite3');
    device = DeviceFolders(
      await Directory('${root.path}/source').create(),
      Directory('${root.path}/staging'),
    );
    cloud = CloudFolders();
    scheduler = RecordingScheduler();
    background = TestSyncBackground();
    ui = controller();
    now = DateTime(2026, 1, 2, 12);
  });
  tearDown(() async {
    await ui.disconnect();
    await journal.close();
    ui.dispose();
    await root.delete(recursive: true);
  });

  test('daily time validation and serialization', () {
    expect(
      () => BackupSchedule(created: created, hour: 24),
      throwsFormatException,
    );
    expect(
      () => BackupSchedule(created: created, minute: -1),
      throwsFormatException,
    );
    expect(
      BackupSchedule.fromJson(schedule().toJson()).toJson(),
      schedule().toJson(),
    );
    expect(schedule().dueSlot(created), isNull);
    expect(schedule().dueSlot(now), '2026-01-02');
    expect(schedule().next(now), DateTime(2026, 1, 3, 10, 20));
  });
  test(
    'daily schedules coalesce missed days and deduplicate clock reversal',
    () {
      final daily = schedule();
      final current = DateTime(2026, 1, 12, 12);
      expect(daily.dueSlot(current), '2026-01-12');
      expect(daily.next(current), DateTime(2026, 1, 13, 10, 20));
      expect(daily.handled('2026-01-10', '2026-01-12'), isTrue);
      expect(daily.dueSlot(created), isNull);
    },
  );

  test(
    'calendar day construction follows DST and has one slot per wall date',
    () {
      final daily = BackupSchedule(
        created: DateTime(2026, 1, 1),
        hour: 2,
        minute: 30,
      );
      final before = DateTime(2026, 3, 7, 23);
      expect(daily.next(before), DateTime(2026, 3, 8, 2, 30));
      final fall = BackupSchedule(created: created, hour: 1, minute: 30);
      final first = DateTime(2026, 11, 1, 1, 30);
      final slot = fall.dueSlot(first)!;
      expect(
        fall.handled(fall.dueSlot(first.add(const Duration(hours: 1)))!, slot),
        isTrue,
      );
    },
  );

  test(
    'schedule and revision survive restart; receipts survive edits',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      await ui.run(pair);
      final receipt = await journal.receipt(pair.id, 'local', ['photo.jpg']);
      final updated = await add(value: schedule(), replacing: pair);
      expect(updated.id, pair.id);
      expect(updated.revision, isNot(pair.revision));
      expect(scheduler.jobs[updated.id], updated.revision);
      expect(await journal.receipt(pair.id, 'local', ['photo.jpg']), receipt);
      await journal.close();
      final restored = await journal.pair(pair.id);
      expect(restored!.schedule!.hour, 10);
      expect(restored.revision, updated.revision);
      expect(
        jsonEncode(restored.toJson()),
        isNot(contains(account.appPassword)),
      );
    },
  );

  test(
    'registration failure is surfaced, persists intent and can reconcile',
    () async {
      scheduler.fail = true;
      await expectLater(add(), throwsA(isA<BackupScheduleFailure>()));
      expect(ui.error, contains('settings saved, but scheduling failed'));
      final saved = (await journal.pairs(syncAccount(account))).single;
      expect(saved.schedule, isNotNull);
      scheduler.fail = false;
      final restored = controller();
      await restored.load();
      expect(scheduler.jobs[saved.id], saved.revision);
      // Both controllers share this fixture's journal; only the owner disposes it.
    },
  );

  test(
    'schedule load errors identify registration and retry without clearing pairs or receipts',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      await ui.run(pair);
      scheduler.fail = true;
      final restored = controller();
      await restored.load();
      expect(restored.error, contains('register backup schedules'));
      expect(restored.error, contains('schedule_denied'));
      expect(restored.pairs.single.id, pair.id);
      expect(await journal.receipt(pair.id, 'local', ['photo.jpg']), isNotNull);
      scheduler.fail = false;
      await restored.load();
      expect(restored.error, isNull);
      expect(scheduler.jobs[pair.id], pair.revision);
    },
  );

  test(
    'headless run uses receipts and no picker, UI engine or legacy service',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      ui.setForeground(false);
      expect(await runner().run(pair.id, pair.revision), isTrue);
      expect(cloud.uploads, 1);
      expect(device.picks, 0);
      expect(background.starts, 0);
      expect((await journal.state(pair.id))['status'], 'success');
      expect((await journal.state(pair.id))['slot'], '2026-01-02');
      expect((await journal.pair(pair.id))!.lastRun, isNotNull);
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 1);
      now = now.add(const Duration(days: 1));
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 1);
      expect((await journal.state(pair.id))['slot'], '2026-01-03');
    },
  );

  test(
    'missing credentials, wrong account, stale revision, disabled and removed are no-ops',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      await runner(loggedOut: true).run(pair.id, pair.revision);
      final other = Account(
        server: account.server,
        userId: 'other',
        loginName: 'other',
        appPassword: 'not-persisted',
        displayName: 'Other',
      );
      await runner(credentials: other).run(pair.id, pair.revision);
      await runner().run(pair.id, 'obsolete');
      await journal.enableAccount(pair.account, false);
      await runner().run(pair.id, pair.revision);
      await journal.forget(pair.id);
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 0);
      expect(device.exports, 0);
    },
  );

  test(
    'unmetered non-Wi-Fi errors persist and retry without consuming slot',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      device.wifi = false;
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 0);
      expect((await journal.state(pair.id))['error'], contains('Wi-Fi'));
      expect((await journal.state(pair.id))['slot'], isNull);
      device.wifi = true;
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 1);
    },
  );

  test(
    'failed transfer does not consume occurrence or produce receipt; retry resumes',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      cloud.interrupted = true;
      await runner().run(pair.id, pair.revision);
      expect((await journal.state(pair.id))['status'], 'error');
      expect(await journal.receipt(pair.id, 'local', ['photo.jpg']), isNull);
      cloud.interrupted = false;
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 1);
      expect((await journal.state(pair.id))['status'], 'success');
    },
  );

  test(
    'foreground-service fallback and locked secure credentials fail visibly without transfers',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      final noNotification = ScheduledBackupRunner(
        journal: journal,
        lock: lock,
        readAccount: () async => account,
        client: cloud,
        closeClient: () {},
        access: device,
        clock: () => now,
        prepareExecution: () async {
          throw PlatformException(code: 'scheduled_background');
        },
      );
      await noNotification.run(pair.id, pair.revision);
      expect((await journal.state(pair.id))['error'], contains('notification'));
      expect(cloud.uploads, 0);
      final lockedCredentials = ScheduledBackupRunner(
        journal: journal,
        lock: lock,
        readAccount: () async {
          throw PlatformException(code: 'device_locked');
        },
        client: cloud,
        closeClient: () {},
        access: device,
        clock: () => now,
      );
      expect(await lockedCredentials.run(pair.id, pair.revision), isFalse);
      expect((await journal.state(pair.id))['error'], contains('unlock'));
      expect(cloud.uploads, 0);
    },
  );

  test(
    'manual account lock excludes scheduled runner and another manual controller',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      final entered = Completer<void>(), release = Completer<void>();
      cloud.holdUpload = () async {
        entered.complete();
        await release.future;
      };
      final work = ui.run(pair);
      await entered.future;
      expect(await runner().run(pair.id, pair.revision), isFalse);
      final another = controller();
      await another.run(pair);
      expect(another.error, contains('Another manual or scheduled'));
      release.complete();
      await work;
      expect(cloud.uploads, 1);
    },
  );

  test(
    'worker lock excludes manual runs, editing and removal during transfer',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      final entered = Completer<void>(), release = Completer<void>();
      cloud.holdUpload = () async {
        entered.complete();
        await release.future;
      };
      final scheduled = runner();
      final work = scheduled.run(pair.id, pair.revision);
      await entered.future;
      await ui.run(pair);
      expect(ui.error, contains('Another manual or scheduled'));
      await expectLater(add(replacing: pair), throwsStateError);
      await expectLater(ui.forget(pair), throwsStateError);
      await scheduled.stop('Cancelled by test');
      release.complete();
      await work;
      expect(cloud.uploads, 1);
      expect((await journal.state(pair.id))['status'], 'interrupted');
      expect(await journal.receipt(pair.id, 'local', ['photo.jpg']), isNotNull);
    },
  );

  test(
    'time budget stops subsequent files, persists reason and retains receipts',
    () async {
      final pair = await add();
      await device.put('a.jpg', 'a');
      await device.put('b.jpg', 'b');
      final entered = Completer<void>(), release = Completer<void>();
      cloud.holdUpload = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final scheduled = runner(
        budget: const Duration(milliseconds: 100),
        close: () {
          if (!release.isCompleted) release.complete();
        },
      );
      await scheduled.run(pair.id, pair.revision);
      expect(cloud.uploads, lessThanOrEqualTo(1));
      expect((await journal.state(pair.id))['error'], contains('time budget'));
      expect((await journal.state(pair.id))['slot'], isNull);
    },
  );

  test(
    'logout disables and cancels all persisted jobs while retaining originals and receipts',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      await ui.run(pair);
      await ui.disconnect();
      expect(await journal.accountEnabled(pair.account), isFalse);
      expect(scheduler.jobs, isEmpty);
      expect(await journal.receipt(pair.id, 'local', ['photo.jpg']), isNotNull);
      await runner().run(pair.id, pair.revision);
      expect(cloud.uploads, 1);
      expect(await device.file(['photo.jpg']).readAsString(), 'original');
    },
  );

  test(
    'remove cancels job and deletes settings, never device or cloud files',
    () async {
      final pair = await add();
      await device.put('photo.jpg', 'original');
      await ui.run(pair);
      await ui.forget(pair);
      expect(scheduler.jobs, isEmpty);
      expect(await journal.pair(pair.id), isNull);
      expect(await journal.state(pair.id), isEmpty);
      expect(cloud.files, isNotEmpty);
      expect(await device.file(['photo.jpg']).exists(), isTrue);
    },
  );

  test(
    'iOS scheduler port rejects schedules and preserves manual-only defaults',
    () async {
      expect(UnsupportedBackupScheduler().supported, isFalse);
      await expectLater(
        UnsupportedBackupScheduler().put(
          'pair',
          'rev',
          schedule(),
          wifiOnly: true,
        ),
        throwsUnsupportedError,
      );
      await ui.load();
      await ui.add(
        'Manual',
        const DeviceFolder('grant', 'Selected', 'folder-id'),
        ['Backup'],
      );
      expect(ui.pairs.single.schedule, isNull);
      expect(scheduler.jobs, isEmpty);
    },
  );

  test(
    'journal upgrade retains account pair and bidirectional transfer receipts',
    () async {
      final path = '${root.path}/v1.sqlite3';
      final old = await databaseFactory.openDatabase(
        path,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: (db, _) async {
            await db.execute(
              'CREATE TABLE pairs (id TEXT PRIMARY KEY, account TEXT NOT NULL, payload TEXT NOT NULL)',
            );
            await db.execute(
              'CREATE TABLE receipts (pair TEXT NOT NULL, side TEXT NOT NULL, path TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, target_version TEXT NOT NULL, PRIMARY KEY(pair,side,path))',
            );
          },
        ),
      );
      final pair = await add();
      await old.insert('pairs', {
        'id': pair.id,
        'account': pair.account,
        'payload': jsonEncode(pair.toJson()),
      });
      await old.insert('receipts', {
        'pair': pair.id,
        'side': 'local',
        'path': '["a"]',
        'version': '1',
        'target': '["a"]',
        'target_version': '2',
      });
      await old.close();
      final upgraded = SyncJournal(path: path);
      expect((await upgraded.pairs(pair.account)).single.id, pair.id);
      expect(
        (await upgraded.receipt(pair.id, 'local', ['a']))!['target_version'],
        '2',
      );
      await upgraded.writeState(pair.id, {'status': 'success'});
      expect((await upgraded.state(pair.id))['status'], 'success');
      await upgraded.close();
    },
  );

  testWidgets('schedule editor offers manual and daily time only', (
    tester,
  ) async {
    await tester.runAsync(ui.load);
    final app = AppController(
      store: MemoryStore(),
      client: cloud,
      folderSyncController: ui,
    )..account = account;
    await tester.pumpWidget(
      MaterialApp(home: BackupSetupScreen(controller: app)),
    );
    expect(find.text('Schedule'), findsOneWidget);
    expect(find.text('Time'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<bool>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Daily').last);
    await tester.pumpAndSettle();
    expect(find.text('Time'), findsOneWidget);
    expect(find.text('Best effort'), findsOneWidget);
    expect(find.text('Only while charging'), findsNothing);
    expect(find.text('Continue in background'), findsNothing);
    expect(find.text('Cron'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
