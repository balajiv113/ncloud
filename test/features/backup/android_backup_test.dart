import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:ncloud/features/backup/model/backup_schedule.dart';
import 'package:ncloud/features/backup/background/android_backup.dart';
import 'package:workmanager/workmanager.dart';

class RecordingWorkmanager extends WorkmanagerPlatform {
  bool failInitialization = true;
  int initialized = 0;
  Map<String, dynamic>? payload;
  Constraints? constraints;
  ForegroundServiceConfig? foreground;
  ExistingPeriodicWorkPolicy? policy;
  Duration? frequency;
  String? unique, task, cancelled;
  final cancelledAll = <String>[];
  final oneOffs =
      <
        ({
          String unique,
          String task,
          Map<String, dynamic>? data,
          Duration? delay,
          Constraints? constraints,
          ExistingWorkPolicy? policy,
        })
      >[];

  @override
  Future<void> initialize(
    Function callbackDispatcher, {
    bool isInDebugMode = false,
  }) async {
    initialized++;
    expect(callbackDispatcher, backupDispatcher);
    if (failInitialization) throw PlatformException(code: 'init_denied');
  }

  @override
  Future<void> registerPeriodicTask(
    String uniqueName,
    String taskName, {
    Duration? frequency,
    Duration? flexInterval,
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingPeriodicWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    ForegroundServiceConfig? foregroundServiceConfig,
  }) async {
    unique = uniqueName;
    task = taskName;
    payload = inputData;
    this.constraints = constraints;
    foreground = foregroundServiceConfig;
    policy = existingWorkPolicy;
    this.frequency = frequency;
  }

  @override
  Future<void> registerOneOffTask(
    String uniqueName,
    String taskName, {
    Map<String, dynamic>? inputData,
    Duration? initialDelay,
    Constraints? constraints,
    ExistingWorkPolicy? existingWorkPolicy,
    BackoffPolicy? backoffPolicy,
    Duration? backoffPolicyDelay,
    String? tag,
    OutOfQuotaPolicy? outOfQuotaPolicy,
    ForegroundServiceConfig? foregroundServiceConfig,
    bool expedited = false,
  }) async {
    oneOffs.add((
      unique: uniqueName,
      task: taskName,
      data: inputData,
      delay: initialDelay,
      constraints: constraints,
      policy: existingWorkPolicy,
    ));
  }

  @override
  Future<void> cancelByUniqueName(String uniqueName) async {
    cancelled = uniqueName;
    cancelledAll.add(uniqueName);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'published Android adapter retries init, uses IDs only, constraints, FGS and update/cancel APIs',
    () async {
      Workmanager(); // Instantiate before replacing its auto-selected platform.
      final previous = WorkmanagerPlatform.instance;
      final platform = RecordingWorkmanager();
      WorkmanagerPlatform.instance = platform;
      addTearDown(() {
        WorkmanagerPlatform.instance = previous;
      });
      final scheduler = AndroidBackupScheduler(android: true);
      final schedule = BackupSchedule(created: DateTime(2026, 1, 1), hour: 10);
      await expectLater(
        scheduler.put('pair', 'revision', schedule, wifiOnly: true),
        throwsA(isA<PlatformException>()),
      );
      platform.failInitialization = false;
      await scheduler.put('pair', 'revision', schedule, wifiOnly: true);
      expect(platform.initialized, 2);
      expect(platform.unique, AndroidBackupScheduler.job('pair'));
      expect(platform.task, backupTask);
      expect(platform.payload, {'pairId': 'pair', 'revision': 'revision'});
      expect(platform.constraints!.networkType, NetworkType.connected);
      expect(platform.constraints!.requiresCharging, isFalse);
      expect(
        platform.foreground!.foregroundServiceType,
        ForegroundServiceType.dataSync,
      );
      expect(
        platform.foreground!.notificationId,
        AndroidBackupScheduler.notificationId('pair'),
      );
      expect(
        AndroidBackupScheduler.notificationId('different'),
        isNot(AndroidBackupScheduler.notificationId('pair')),
      );
      expect(platform.frequency, const Duration(minutes: 15));
      expect(platform.policy, ExistingPeriodicWorkPolicy.update);
      await scheduler.cancel('pair');
      expect(platform.cancelled, AndroidBackupScheduler.job('pair'));
    },
  );

  test(
    'a backup that wants new photos sets a content trigger, and only then',
    () async {
      Workmanager();
      final previous = WorkmanagerPlatform.instance;
      final platform = RecordingWorkmanager()..failInitialization = false;
      WorkmanagerPlatform.instance = platform;
      addTearDown(() => WorkmanagerPlatform.instance = previous);
      final scheduler = AndroidBackupScheduler(android: true);
      final daily = BackupSchedule(created: DateTime(2026, 1, 1), hour: 10);
      await scheduler.put('pair', 'rev', daily, wifiOnly: true);
      expect(platform.oneOffs, isEmpty);
      expect(platform.cancelledAll, [AndroidBackupScheduler.changeJob('pair')]);

      final eager = BackupSchedule(
        created: DateTime(2026, 1, 1),
        hour: 10,
        onNewPhotos: true,
      );
      await scheduler.put('pair', 'rev', eager, wifiOnly: true);
      final trigger = platform.oneOffs.single;
      expect(trigger.unique, AndroidBackupScheduler.changeJob('pair'));
      expect(trigger.task, backupChangeTask);
      expect(trigger.data, {'pairId': 'pair', 'revision': 'rev'});
      expect(trigger.policy, ExistingWorkPolicy.replace);
      expect(trigger.delay, const Duration(minutes: 1));
      expect(trigger.constraints!.networkType, NetworkType.connected);
      expect(
        [for (final t in trigger.constraints!.contentUriTriggers!) t!.uri],
        [
          'content://media/external/images/media',
          'content://media/external/video/media',
        ],
      );
      expect(
        trigger.constraints!.contentUriTriggers!.every(
          (t) => t!.triggerForDescendants,
        ),
        isTrue,
      );

      platform.cancelledAll.clear();
      await scheduler.cancel('pair');
      expect(platform.cancelledAll, [
        AndroidBackupScheduler.changeJob('pair'),
        AndroidBackupScheduler.job('pair'),
      ]);
    },
  );

  test(
    'native worker notification verification fails closed without picker calls',
    () async {
      final methods = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        methods.add(call.method);
        return true;
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NativeFolderAccess.channel,
          null,
        ),
      );
      await NativeFolderAccess().requireWorkerNotification(42);
      expect(methods, ['workerNotification']);
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        throw PlatformException(code: 'scheduled_background');
      });
      await expectLater(
        NativeFolderAccess().requireWorkerNotification(42),
        throwsA(isA<PlatformException>()),
      );
    },
  );
}
