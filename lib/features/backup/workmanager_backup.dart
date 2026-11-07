import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:workmanager/workmanager.dart';

import '../../app/provider_factory.dart';
import '../account/session_store.dart';
import 'folder_sync.dart';
import 'headless_backup.dart';
import 'ios_album_backup.dart';
import '../../models.dart';
import 'sync_run_lock.dart';
import 'sync_schedule.dart';

const backupTask = 'ncloud.folder-backup';

@pragma('vm:entry-point')
void backupDispatcher() {
  WidgetsFlutterBinding.ensureInitialized();
  ScheduledBackupRunner? runner;
  IosAlbumBackupBatch? albumBatch;
  Workmanager().executeTask(
    (task, data) async {
      if (task == iosAlbumTask) {
        final journal = SyncJournal();
        final client = createCloudBackend();
        Future<Account?> readAccount() async {
          final value = await SecureSessionStore().read();
          return value == null ? null : client.restoreAccount(value);
        }

        final scheduler = IosAlbumScheduler(
          journal: journal,
          readAccount: readAccount,
          initialize: () async {},
        );
        albumBatch = IosAlbumBackupBatch(
          scheduler: scheduler,
          createRunner: (_) => ScheduledBackupRunner(
            journal: journal,
            client: client,
            closeClient: client.close,
            lock: NativeSyncRunLock(),
            readAccount: readAccount,
            budget: const Duration(minutes: 2),
          ),
        );
        try {
          return await albumBatch!.run();
        } finally {
          albumBatch = null;
          client.close();
          await journal.close();
        }
      }
      if (task != backupTask ||
          data?['pairId'] is! String ||
          data?['revision'] is! String) {
        return true;
      }
      final journal = SyncJournal();
      final client = createCloudBackend();
      runner = ScheduledBackupRunner(
        journal: journal,
        client: client,
        closeClient: client.close,
        lock: NativeSyncRunLock(),
        prepareExecution: () => NativeFolderAccess().requireWorkerNotification(
          AndroidBackupScheduler.notificationId(data!['pairId'] as String),
        ),
        readAccount: () async {
          final value = await SecureSessionStore().read();
          return value == null ? null : client.restoreAccount(value);
        },
      );
      try {
        return await runner!.run(
          data!['pairId'] as String,
          data['revision'] as String,
        );
      } finally {
        runner = null;
        client.close();
        await journal.close();
      }
    },
    onTaskStopped: (task, reason) async {
      await albumBatch?.stop(
        'iOS stopped album backup: ${reason.name}. Completed transfers are saved.',
      );
      await runner?.stop(
        'Android stopped backup: ${reason.name}. Completed transfers are saved.',
      );
    },
  );
}

Future<void> initializeBackupDispatcher() =>
    AndroidBackupScheduler.initialize();

class AndroidBackupScheduler implements BackupScheduler {
  AndroidBackupScheduler({bool? android})
    : _android = android ?? Platform.isAndroid;
  final bool _android;
  static Future<void>? _initializing;
  static Future<void> initialize() => _initializing ??= Workmanager()
      .initialize(backupDispatcher)
      .onError((error, stack) {
        _initializing = null;
        Error.throwWithStackTrace(error!, stack);
      });

  @override
  bool get supported => _android;
  @override
  String? get notice => null;
  static String job(String id) => 'ncloud.backup.$id';
  static int notificationId(String id) =>
      10000 +
      id.codeUnits.fold<int>(
        0,
        (value, char) => (value * 31 + char) & 0x3fffffff,
      );

  @override
  Future<void> put(
    String pairId,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
  }) async {
    if (!supported) throw UnsupportedError('Scheduled backup is Android only.');
    await initialize();
    await Workmanager().registerPeriodicTask(
      job(pairId),
      backupTask,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.update,
      inputData: {'pairId': pairId, 'revision': revision},
      constraints: Constraints(
        // WorkManager has no Wi-Fi transport constraint. Check actual Wi-Fi
        // before scanning and every transfer, including on unmetered networks.
        networkType: NetworkType.connected,
        requiresCharging: false,
      ),
      foregroundServiceConfig: ForegroundServiceConfig(
        notificationTitle: 'ncloud scheduled backup',
        notificationText: 'Checking due folders · originals are never deleted',
        notificationChannelId: 'ncloud_scheduled_backup',
        notificationChannelName: 'Scheduled folder backups',
        notificationId: notificationId(pairId),
        foregroundServiceType: ForegroundServiceType.dataSync,
      ),
    );
  }

  @override
  Future<void> cancel(String pairId) async {
    if (!supported) return;
    await initialize();
    await Workmanager().cancelByUniqueName(job(pairId));
  }
}
