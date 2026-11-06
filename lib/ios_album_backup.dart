import 'dart:io';

import 'folder_sync.dart';
import 'headless_backup.dart';
import 'models.dart';
import 'sync_schedule.dart';

const iosAlbumTask = 'app.ncloud.album-backup';

class IosAlbumScheduler implements BackupScheduler {
  IosAlbumScheduler({
    required this.journal,
    required this.readAccount,
    required this.initialize,
    bool? ios,
  }) : _ios = ios ?? Platform.isIOS;

  final SyncJournal journal;
  final Future<Account?> Function() readAccount;
  final Future<void> Function() initialize;
  final bool _ios;

  @override
  bool get supported => _ios;

  Future<List<FolderPair>> configuredAlbums() async {
    final session = await readAccount();
    if (session == null) return [];
    final owner = syncAccount(session);
    if (!await journal.accountEnabled(owner)) return [];
    return [
      for (final pair in await journal.pairs(owner))
        if (pair.folder.kind == DeviceSourceKind.photoAlbum &&
            pair.mode == SyncMode.backup &&
            pair.schedule != null)
          pair,
    ]..sort(
      (a, b) =>
          (a.lastRun ?? DateTime(1970)).compareTo(b.lastRun ?? DateTime(1970)),
    );
  }

  Future<void> reconcile() async {
    if (!supported) return;
    final pairs = await configuredAlbums();
    if (pairs.isEmpty) {
      await NativeFolderAccess.channel.invokeMethod<void>('cancelAlbums');
      return;
    }
    await armNextOpportunity(
      requiresCharging: pairs.every((pair) => pair.chargingOnly),
    );
  }

  Future<void> armNextOpportunity({bool requiresCharging = false}) async {
    if (!supported) return;
    await initialize();
    await NativeFolderAccess.channel.invokeMethod<void>('scheduleAlbums', {
      'earliestSeconds': 900,
      'requiresCharging': requiresCharging,
    });
  }

  @override
  Future<void> put(
    String pairId,
    String revision,
    BackupSchedule schedule, {
    required bool wifiOnly,
    required bool chargingOnly,
  }) async {
    if (!supported) {
      throw UnsupportedError('Apple Photos background backup requires iOS.');
    }
    await reconcile();
  }

  @override
  Future<void> cancel(String pairId) => reconcile();
}

/// One fixed OS task checks current saved albums, never a stale job payload.
class IosAlbumBackupBatch {
  IosAlbumBackupBatch({
    required this.scheduler,
    required this.createRunner,
    DateTime Function()? clock,
    this.budget = const Duration(minutes: 5),
  }) : clock = clock ?? DateTime.now;

  final IosAlbumScheduler scheduler;
  final HeadlessBackupRunner Function(FolderPair) createRunner;
  final DateTime Function() clock;
  final Duration budget;
  HeadlessBackupRunner? _active;
  bool _stopped = false;

  Future<void> stop(String reason) async {
    _stopped = true;
    await _active?.stop(reason);
  }

  Future<bool> run() async {
    final started = clock();
    try {
      // Arm the next opportunity before transfers; iOS can destroy the engine
      // at expiration without waiting for Dart's finally blocks.
      await scheduler.armNextOpportunity();
      final pairs = await scheduler.configuredAlbums();
      if (pairs.isEmpty) await scheduler.reconcile();
      for (final pair in pairs) {
        if (_stopped || clock().difference(started) >= budget) break;
        final runner = _active = createRunner(pair);
        await runner.run(pair.id, pair.revision);
        _active = null;
        if ((await scheduler.journal.state(pair.id))['status'] ==
            'interrupted') {
          break;
        }
      }
      await scheduler.journal.writeState(SyncJournal.iosAlbumService, {
        'error': null,
      });
      return true;
    } on Object catch (error) {
      await scheduler.journal.writeState(SyncJournal.iosAlbumService, {
        'error':
            'iOS automatic album backup needs attention (${error.runtimeType}). '
            'Open Folder sync to retry.',
      });
      rethrow;
    } finally {
      _active = null;
    }
  }
}
