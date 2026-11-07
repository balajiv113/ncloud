import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/diagnostics.dart';
import 'package:ncloud/features/backup/folder_sync.dart';
import 'package:ncloud/features/backup/folder_sync_screen.dart';
import 'package:ncloud/features/backup/headless_backup.dart';
import 'package:ncloud/features/backup/ios_album_backup.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/features/backup/sync_run_lock.dart';
import 'package:ncloud/features/backup/sync_schedule.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../app_test.dart' show MemoryStore;
import 'folder_sync_test.dart' show CloudFolders, DeviceFolders;
import '../../nextcloud_client_test.dart' show account;

const album = DeviceFolder(
  'photos:album-id',
  'Trips',
  'photos:album-id',
  kind: DeviceSourceKind.photoAlbum,
);

class AlbumDevice extends DeviceFolders implements PhotoAlbumAccess {
  AlbumDevice(super.root, super.staging);
  bool changed = false;
  final versions = <String, String>{};

  @override
  Future<List<DeviceFolder>> albums() async => [album];

  @override
  Future<List<DeviceEntry>> list(String token, List<String> path) async => [
    for (final item in await super.list(token, path))
      DeviceEntry(
        item.name,
        false,
        -1,
        item.modified,
        contentType: 'image/heic',
        revision: '${item.name}|${versions[item.name] ?? item.modified}',
      ),
  ];

  @override
  Future<File> export(
    String token,
    List<String> path,
    DeviceEntry expected,
  ) async {
    if (changed) {
      throw PlatformException(
        code: 'photos_changed',
        message: 'The album changed. Retry to read its current originals.',
      );
    }
    return super.export(token, path, entry(file(path)));
  }
}

class BatchRunner implements HeadlessBackupRunner {
  BatchRunner(this.callback);
  final Future<void> Function(String id, String revision) callback;
  bool stopped = false;
  @override
  Future<bool> run(String pairId, String revision) async {
    await callback(pairId, revision);
    return true;
  }

  @override
  Future<void> stop(String reason) async {
    stopped = true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late SyncJournal journal;
  late AlbumDevice device;
  late CloudFolders cloud;
  late FolderSyncController ui;
  late IosAlbumScheduler scheduler;
  late Account? session;
  final methods = <MethodCall>[];
  bool scheduleDenied = false;
  bool backgroundSupported = true;
  int initialized = 0;
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  BackupSchedule schedule() =>
      BackupSchedule(created: DateTime(2026, 1, 1), hour: 0);

  Future<FolderPair> add({
    DeviceFolder source = album,
    BackupSchedule? scheduling,
  }) async {
    await ui.load();
    await ui.add(source.name, source, ['Backup'], schedule: scheduling);
    return ui.pairs.last;
  }

  setUp(() async {
    root = await Directory(
      '.dart_tool/ios-album-tests',
    ).absolute.create(recursive: true);
    root = await root.createTemp('run-');
    journal = SyncJournal(
      path: '${root.path}/journal.sqlite3',
      factory: databaseFactoryFfi,
    );
    device = AlbumDevice(
      await Directory('${root.path}/source').create(),
      Directory('${root.path}/stage'),
    );
    cloud = CloudFolders();
    session = account;
    methods.clear();
    initialized = 0;
    scheduleDenied = false;
    backgroundSupported = true;
    messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
      call,
    ) async {
      methods.add(call);
      if (call.method == 'albumBackgroundSupported') return backgroundSupported;
      if (call.method == 'scheduleAlbums' && scheduleDenied) {
        throw PlatformException(
          code: 'backup_schedule',
          message: 'Allow Background App Refresh in iOS Settings and retry.',
        );
      }
      return null;
    });
    scheduler = IosAlbumScheduler(
      journal: journal,
      readAccount: () async => session,
      initialize: () async {
        initialized++;
      },
      ios: true,
    );
    ui = FolderSyncController(
      client: cloud,
      account: () => session,
      access: device,
      journal: journal,
      scheduler: scheduler,
      android: false,
      ios: true,
      runLock: InProcessSyncRunLock(),
    );
    ui.setForeground(false);
  });

  tearDown(() async {
    await ui.disconnect();
    ui.dispose();
    await journal.close();
    messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null);
    await root.delete(recursive: true);
  });

  test(
    'album unknown-size originals upload once, new members recur, deletions never propagate',
    () async {
      final pair = await add();
      expect(
        FolderPair.fromJson(pair.toJson()).folder.kind,
        DeviceSourceKind.photoAlbum,
      );
      await device.put('IMG_0001_assetA.HEIC', 'original-one');
      await ui.run(pair, headless: true);
      expect(ui.error, isNull);
      expect(
        cloud.files['Backup/Trips/IMG_0001_assetA.HEIC']!.$1,
        'original-one'.codeUnits,
      );
      await ui.run(pair, headless: true);
      expect(cloud.uploads, 1);
      await device.put('IMG_0001_assetB.HEIC', 'original-two');
      await ui.run(pair, headless: true);
      expect(cloud.uploads, 2);
      await device.file(['IMG_0001_assetA.HEIC']).delete();
      await ui.run(pair, headless: true);
      expect(cloud.files, hasLength(2));
      expect(device.imports, 0);
      expect(device.picks, 0);
      expect(methods.where((c) => c.method == 'scheduleAlbums'), isEmpty);
    },
  );

  test(
    'source changes fail visibly without receipt and edited originals keep both versions',
    () async {
      final pair = await add();
      await device.put('photo.HEIC', 'before');
      device.changed = true;
      await ui.run(pair, headless: true);
      expect(ui.error, contains('album changed'));
      expect(cloud.uploads, 0);
      expect(await journal.receipt(pair.id, 'local', ['photo.HEIC']), isNull);
      device.changed = false;
      await ui.run(pair, headless: true);
      device.versions['photo.HEIC'] = 'edited';
      await device.put('photo.HEIC', 'after-edit');
      await ui.run(pair, headless: true);
      expect(cloud.uploads, 2);
      expect(cloud.files['Backup/Trips/photo.HEIC']!.$1, 'before'.codeUnits);
    },
  );

  test(
    'automatic foreground checks reuse slots, resume picks up new members and disabling stops recurrence',
    () async {
      final pair = await add(scheduling: schedule());
      await device.put('first.HEIC', 'one');
      ui.setForeground(true);
      await ui.checkAutomaticAlbums();
      expect(ui.error, isNull);
      expect(cloud.uploads, 1);
      expect((await journal.state(pair.id))['slot'], isNotNull);
      await device.put('second.HEIC', 'two');
      await ui.checkAutomaticAlbums();
      expect(cloud.uploads, 1);
      ui.setForeground(false);
      await ui.checkAutomaticAlbums();
      expect(cloud.uploads, 1);
      ui.setForeground(true);
      await ui.checkAutomaticAlbums();
      expect(cloud.uploads, 1);
      await ui.add(pair.name, pair.folder, pair.remote, replacing: pair);
      expect(ui.pairs.single.schedule, isNull);
      expect(ui.pairs.single.lastRun, isNotNull);
      await device.put('third.HEIC', 'three');
      ui.setForeground(false);
      ui.setForeground(true);
      await ui.checkAutomaticAlbums();
      expect(cloud.uploads, 1);
      await ui.run(ui.pairs.single);
      expect(cloud.uploads, 3);
    },
  );

  test(
    'Photos is upload-only and Files unknown sizes/background schedules are rejected',
    () async {
      await ui.load();
      await expectLater(
        ui.add('No', const DeviceFolder('grant', 'Files', 'grant'), [
          'Backup',
        ], schedule: schedule()),
        throwsFormatException,
      );
      final pair = await add(
        source: const DeviceFolder('grant', 'Trips', 'grant'),
      );
      await device.put('photo.HEIC', 'original');
      await ui.run(pair, headless: true);
      expect(ui.error, isNotNull);
      expect(cloud.uploads, 0);
    },
  );

  test(
    'one fixed background task reconciles albums sharing a parent and cancels the last removal',
    () async {
      final first = await add(scheduling: schedule());
      expect(methods.last.method, 'scheduleAlbums');
      expect(methods.last.arguments, {
        'earliestSeconds': 900,
        'requiresCharging': false,
      });
      final second = await add(
        source: const DeviceFolder(
          'photos:other',
          'Favorites',
          'photos:other',
          kind: DeviceSourceKind.photoAlbum,
        ),
        scheduling: schedule(),
      );
      expect(methods.last.arguments, {
        'earliestSeconds': 900,
        'requiresCharging': false,
      });
      expect(initialized, greaterThan(0));
      await ui.forget(first);
      expect((await scheduler.configuredAlbums()).map((p) => p.id), [
        second.id,
      ]);
      await ui.forget(second);
      expect(methods.last.method, 'cancelAlbums');
      expect(cloud.uploads, 0);
      expect(
        methods.every(
          (call) =>
              call.arguments == null ||
              (call.arguments as Map).keys.every(
                (key) => ['earliestSeconds', 'requiresCharging'].contains(key),
              ),
        ),
        isTrue,
      );
    },
  );

  test(
    'registration denial preserves saved intent and exposes actionable iOS error on retry',
    () async {
      scheduleDenied = true;
      await expectLater(
        add(scheduling: schedule()),
        throwsA(isA<BackupScheduleFailure>()),
      );
      final saved = (await journal.pairs(syncAccount(account))).single;
      expect(saved.schedule, isNotNull);
      await ui.load();
      expect(ui.error, contains('Background App Refresh'));
      scheduleDenied = false;
      await ui.load();
      expect(ui.error, isNull);
      expect(ui.pairs.single.id, saved.id);
    },
  );

  test(
    'background batch re-arms before execution and revalidates account, source and slot',
    () async {
      final pair = await add(scheduling: schedule());
      await device.put('photo.HEIC', 'original');
      methods.clear();
      final batch = IosAlbumBackupBatch(
        scheduler: scheduler,
        createRunner: (_) {
          expect(methods.last.method, 'scheduleAlbums');
          return ScheduledBackupRunner(
            journal: journal,
            lock: InProcessSyncRunLock(),
            readAccount: () async => session,
            client: cloud,
            closeClient: () {},
            access: device,
          );
        },
      );
      expect(await batch.run(), isTrue);
      expect(cloud.uploads, 1);
      expect((await journal.state(pair.id))['slot'], isNotNull);
      await batch.run();
      expect(cloud.uploads, 1);
      await journal.enableAccount(syncAccount(account), false);
      await batch.run();
      expect(methods.last.method, 'cancelAlbums');
      expect(cloud.uploads, 1);
      expect(device.picks, 0);
    },
  );

  test(
    'locked credentials retain a future opportunity and persist a surfaced service failure',
    () async {
      await add(scheduling: schedule());
      final lockedScheduler = IosAlbumScheduler(
        journal: journal,
        readAccount: () async =>
            throw PlatformException(code: 'keychain_locked'),
        initialize: () async {},
        ios: true,
      );
      methods.clear();
      await expectLater(
        IosAlbumBackupBatch(
          scheduler: lockedScheduler,
          createRunner: (_) =>
              throw StateError('Must not run without credentials'),
        ).run(),
        throwsA(isA<PlatformException>()),
      );
      expect(methods.map((call) => call.method), [
        'albumBackgroundSupported',
        'scheduleAlbums',
      ]);
      expect(
        (await journal.state(SyncJournal.iosAlbumService))['error'],
        contains('needs attention'),
      );
      expect(cloud.uploads, 0);
    },
  );

  test(
    'stopping an iOS batch stops its active runner and prevents the next album',
    () async {
      await add(scheduling: schedule());
      await add(
        source: const DeviceFolder(
          'photos:other',
          'Other',
          'photos:other',
          kind: DeviceSourceKind.photoAlbum,
        ),
        scheduling: schedule(),
      );
      final started = Completer<void>(), release = Completer<void>();
      var runs = 0;
      final runner = BatchRunner((id, revision) async {
        runs++;
        started.complete();
        await release.future;
      });
      final batch = IosAlbumBackupBatch(
        scheduler: scheduler,
        createRunner: (_) => runner,
      );
      final run = batch.run();
      await started.future;
      await batch.stop('Expired');
      release.complete();
      await run;
      expect(runner.stopped, isTrue);
      expect(runs, 1);
    },
  );

  test(
    'native adapter requests albums only explicitly and preserves revision and permission errors',
    () async {
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        methods.add(call);
        if (call.method == 'albums') {
          return [
            {
              'token': album.token,
              'name': album.name,
              'identity': album.identity,
            },
          ];
        }
        if (call.method == 'list') {
          return [
            {
              'name': 'original.HEIC',
              'directory': false,
              'size': -1,
              'modified': 1000,
              'revision': 'resource-revision',
              'contentType': 'image/heic',
            },
          ];
        }
        if (call.method == 'export') {
          expect((call.arguments as Map)['version'], 'resource-revision');
          return '${root.path}/fake.part';
        }
        return null;
      });
      final access = NativeFolderAccess();
      expect((await access.albums()).single.kind, DeviceSourceKind.photoAlbum);
      final entry = (await access.list(album.token, [])).single;
      expect(entry.version, 'resource-revision');
      await access.export(album.token, [entry.name], entry);
      expect(methods.map((c) => c.method), ['albums', 'list', 'export']);
      messenger.setMockMethodCallHandler(
        NativeFolderAccess.channel,
        (_) async => throw PlatformException(
          code: 'photos_permission',
          message: 'Allow full Photos access for whole album backup.',
        ),
      );
      await expectLater(access.albums(), throwsA(isA<PlatformException>()));
      expect(
        errorMessage(
          PlatformException(
            code: 'photos_permission',
            message: 'Allow full Photos access.',
          ),
        ),
        'Allow full Photos access.',
      );
    },
  );

  testWidgets(
    'iOS setup offers entire albums, upload-only and explicit automatic backup, never individual assets',
    (tester) async {
      await tester.runAsync(() async {
        await ui.load();
      });
      final controller = AppController(
        store: MemoryStore(),
        client: cloud,
        folderSyncController: ui,
      );

      await tester.pumpWidget(
        MaterialApp(home: FolderSyncScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Add backup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Photos album'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();
      expect(find.text('Schedule'), findsOneWidget);
      expect(find.text('Transfer direction'), findsNothing);
      expect(find.textContaining('individual files'), findsNothing);
      expect(device.picks, 0);
      expect(cloud.uploads, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'simulator daily schedules save without background initialization',
    (tester) async {
      await tester.runAsync(() async {
        backgroundSupported = false;
        ui.setForeground(true);
        final pair = await add(scheduling: schedule());
        expect(pair.schedule, isNotNull);
        expect(scheduler.notice, 'App open only');
        expect(initialized, 0);
        expect(
          methods.where((call) => call.method == 'scheduleAlbums'),
          isEmpty,
        );
        await device.put('photo.HEIC', 'original');
        await ui.run(pair);
        expect(ui.error, isNull);
        expect(cloud.uploads, 1);
      });
      await tester.pumpWidget(
        MaterialApp(
          home: FolderSyncScreen(
            controller: AppController(
              store: MemoryStore(),
              client: cloud,
              folderSyncController: ui,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('App open only'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test(
    'missing native availability fails explicitly without losing settings',
    () async {
      messenger.setMockMethodCallHandler(
        NativeFolderAccess.channel,
        (_) async => null,
      );
      await expectLater(
        add(scheduling: schedule()),
        throwsA(isA<BackupScheduleFailure>()),
      );
      expect(ui.pairs.single.schedule, isNotNull);
      expect(initialized, 0);
    },
  );
}
