import 'dart:async';
import 'package:flutter/services.dart';

import 'cloud_backend.dart';
import 'folder_sync.dart';
import 'models.dart';
import 'sync_run_lock.dart';

abstract interface class HeadlessBackupRunner {
  Future<bool> run(String pairId, String revision);
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
  FolderSyncController? _controller;
  String? _pairId;
  bool _stopped = false;
  String? _stopReason;

  @override
  Future<void> stop(String reason) async {
    _stopped = true;
    _stopReason = reason;
    _controller?.requestPause();
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
  Future<bool> run(String pairId, String revision) async {
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
      _controller?.requestPause();
      closeClient();
    }

    try {
      final pair = await journal.pair(pairId);
      if (_stopped ||
          pair == null ||
          pair.account != owner ||
          pair.revision != revision ||
          pair.schedule == null ||
          pair.mode != SyncMode.backup ||
          !await journal.accountEnabled(owner)) {
        return true;
      }
      final state = await journal.state(pairId);
      final slot = pair.schedule!.dueSlot(clock());
      if (slot == null ||
          (state['revision'] == revision &&
              pair.schedule!.handled(slot, state['slot'] as String?))) {
        return true;
      }
      _pairId = pairId;
      final controller = _controller = FolderSyncController(
        client: client,
        account: () => session,
        access: access,
        journal: journal,
        android: false,
        runLock: _HeldRunLock(),
        prepareExecution: prepareExecution,
      );
      // The timer only requests cancellation. The run retains its lock until
      // current operations settle; engine teardown also releases native locks.
      deadline = Timer(budget, () {
        pendingStop = stop(
          'Android backup time budget reached; retry will resume from receipts.',
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
                'phase': controller.phase,
                'transferred': controller.transferred,
                'heartbeat': clock().toUtc().toIso8601String(),
              });
            }
          } finally {
            checking = false;
          }
        }).catchError(rememberFailure);
      });
      await controller.run(pair, headless: true);
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
      if (!_stopped &&
          controller.error == null &&
          (await journal.state(pairId))['status'] == 'success') {
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
      _controller = null;
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
