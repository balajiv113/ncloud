import 'dart:async';
import 'package:flutter/services.dart';

import '../../../core/cloud/cloud_backend.dart';
import '../platform/folder_access.dart';
import '../state/sync_journal.dart';
import '../engine/sync_runner.dart';
import '../../../models.dart';
import '../platform/sync_run_lock.dart';

abstract interface class HeadlessBackupRunner {
  Future<bool> run(String pairId, String revision, {bool onChange = false});
  Future<void> stop(String reason);
}

class ScheduledBackupRunner implements HeadlessBackupRunner {
  ScheduledBackupRunner({
    required this.journal,
    required this.lock,
    required this.readAccount,
    required this.client,
    required this.closeClient,
    FolderAccess? access,
    DateTime Function()? clock,
    this.budget = const Duration(minutes: 8),
    this.prepareExecution,
  }) : access = access ?? NativeFolderAccess(),
       clock = clock ?? DateTime.now;

  final SyncJournal journal;
  final SyncRunLock lock;
  final Future<Account?> Function() readAccount;
  final CloudBackend client;
  final void Function() closeClient;
  final FolderAccess access;
  final DateTime Function() clock;
  final Duration budget;
  final Future<void> Function()? prepareExecution;
  SyncRunner? _runner;
  String? _pairId;
  bool _stopped = false;
  String? _stopReason;

  @override
  Future<void> stop(String reason) async {
    _stopped = true;
    _stopReason = reason;
    _runner?.requestStop();
    closeClient();
    if (_pairId case final id?) {
      await journal.writeState(id, {
        'status': 'interrupted',
        'error': reason,
        'finished': clock().toUtc().toIso8601String(),
      });
    }
  }

  @override
  Future<bool> run(
    String pairId,
    String revision, {
    bool onChange = false,
  }) async {
    Account? session;
    try {
      session = await readAccount();
    } on PlatformException catch (error) {
      await journal.writeState(pairId, {
        'status': 'error',
        'error':
            'Could not unlock the saved account (${error.code}). Open ncloud and retry.',
      });
      return false;
    } on FormatException {
      await journal.writeState(pairId, {
        'status': 'error',
        'error': 'The saved account is invalid. Sign in again.',
      });
      return true;
    }
    if (session == null || _stopped) return true;
    final owner = syncAccount(session);
    if (!await lock.acquire(owner)) return false;
    Timer? deadline, checkpoint;
    Future<void>? pendingCheckpoint, pendingStop;
    Object? checkpointError;
    StackTrace? checkpointStack;
    void rememberFailure(Object error, StackTrace stack) {
      checkpointError = error;
      checkpointStack = stack;
      _stopped = true;
      _runner?.requestStop();
      closeClient();
    }

    try {
      final pair = await journal.pair(pairId);
      if (_stopped ||
          pair == null ||
          pair.account != owner ||
          pair.revision != revision ||
          pair.schedule == null ||
          (onChange && !pair.schedule!.onNewPhotos) ||
          !await journal.accountEnabled(owner)) {
        return true;
      }
      // A change-triggered run is not tied to the daily time, and does not use
      // up that day's occurrence.
      final slot = onChange
          ? null
          : pair.dueSlot(await journal.state(pairId), clock());
      if (!onChange && slot == null) return true;
      _pairId = pairId;
      final runner = _runner = SyncRunner(
        client: client,
        access: access,
        journal: journal,
        runLock: _HeldRunLock(),
        foreground: () => true,
        accountKey: () => owner,
        onChanged: () {},
        headless: true,
        prepareExecution: prepareExecution,
      );
      // The timer only requests cancellation. The run retains its lock until
      // current operations settle; engine teardown also releases native locks.
      deadline = Timer(budget, () {
        pendingStop = stop(
          'Backup time budget reached; retry will resume from receipts.',
        ).catchError(rememberFailure);
      });
      var checking = false;
      checkpoint = Timer.periodic(const Duration(seconds: 2), (_) {
        if (checking) return;
        checking = true;
        pendingCheckpoint = Future<void>.sync(() async {
          try {
            if (!await journal.accountEnabled(owner) ||
                (await journal.state(pairId))['cancel'] == true) {
              await stop('Backup cancelled. Completed transfers are saved.');
            } else {
              await journal.writeState(pairId, {
                'phase': runner.progress.phase,
                'transferred': runner.progress.transferred,
                'heartbeat': clock().toUtc().toIso8601String(),
              });
            }
          } finally {
            checking = false;
          }
        }).catchError(rememberFailure);
      });
      await runner.run(session, pair);
      checkpoint.cancel();
      deadline.cancel();
      await pendingCheckpoint;
      await pendingStop;
      if (checkpointError != null) {
        Error.throwWithStackTrace(checkpointError!, checkpointStack!);
      }
      if (_stopped) {
        await journal.writeState(pairId, {
          'status': 'interrupted',
          'error': _stopReason,
          'finished': clock().toUtc().toIso8601String(),
        });
      }
      // A run that finished with a few files it could not back up still used
      // today's occurrence; those files are tried again at the next one, and
      // retrying all day would only drain the battery.
      if (!onChange &&
          !_stopped &&
          runner.error == null &&
          const {
            'success',
            'partial',
          }.contains((await journal.state(pairId))['status'])) {
        await journal.writeState(pairId, {
          'revision': revision,
          'slot': slot,
          'nextDue': pair.schedule!.next(clock()).toUtc().toIso8601String(),
        });
      }
      return true;
    } finally {
      checkpoint?.cancel();
      deadline?.cancel();
      await pendingCheckpoint;
      await pendingStop;
      _runner = null;
      _pairId = null;
      await lock.release(owner);
    }
  }
}

class _HeldRunLock implements SyncRunLock {
  @override
  Future<bool> acquire(String account) async => true;
  @override
  Future<void> release(String account) async {}
}
