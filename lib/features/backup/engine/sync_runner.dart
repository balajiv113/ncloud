import 'dart:async';

import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';
import '../platform/folder_access.dart';
import '../platform/sync_background.dart';
import 'sync_engine.dart';
import '../platform/device_library.dart';
import 'backup_preview.dart';
import 'pair_policy.dart';
import 'sync_errors.dart';
import '../state/sync_journal.dart';
import '../platform/sync_run_lock.dart';

/// How a run ended, with the pair's state as the journal last recorded it.
class SyncRunResult {
  const SyncRunResult(this.state);

  /// The journal's final state for the pair, or null when the run never got
  /// the account's lock and so recorded nothing.
  final Map<String, dynamic>? state;
}

/// One run of one folder pair, from start to finish.
///
/// It takes the account's run lock so only one backup runs at a time, records
/// progress and the final state in the journal, keeps Android's upload service
/// alive while it works, and turns any failure into a message for the user.
/// The sync itself is the [SyncEngine]'s job. Everything here is plain Dart, so
/// the foreground screen and the scheduled background runner use the same code.
class SyncRunner {
  SyncRunner({
    required this.client,
    required this.access,
    required this.journal,
    required this.runLock,
    this.backgroundService,
    required this.foreground,
    required this.accountKey,
    required this.onChanged,
    SyncProgress? progress,
    this.headless = false,
    this.prepareExecution,
    this.onBackgroundPause,
  }) : progress = progress ?? SyncProgress();

  final CloudBackend client;
  final FolderAccess access;
  final SyncJournal journal;
  final SyncRunLock runLock;

  /// Android's upload service, which keeps a foreground run alive in the
  /// background. Null where there is none, as on iOS and for headless runs.
  final SyncBackground? backgroundService;

  /// Whether the app is in the foreground; a run stops when it is not, unless
  /// it is [headless] or Android's upload service keeps it alive.
  final bool Function() foreground;

  /// The sync account key the app is signed in as; a run stops if it changes.
  final String? Function() accountKey;
  final void Function() onChanged;

  /// A scheduled run without the app's UI.
  final bool headless;
  final Future<void> Function()? prepareExecution;

  /// Called when Android asks the upload service to pause.
  final void Function()? onBackgroundPause;

  final SyncProgress progress;

  /// Why the run did not complete, if it did not: a failure, or the reason the
  /// system gave for pausing. Null after a success or a user's pause.
  String? error;
  String? errorCode;

  bool _stop = false;
  bool _backgroundActive = false;
  bool _backgroundRequested = false;

  /// Whether Android's upload service was asked to keep this run going while
  /// the app is in the background.
  bool get backgroundRequested => _backgroundRequested;

  /// Whether a stop was requested, by the user, the system or a shutdown.
  bool get stopRequested => _stop;

  /// Asks the run to end after the file in progress.
  void requestStop() => _stop = true;

  void _check(FolderPair pair) {
    if (_stop ||
        (!foreground() && !_backgroundActive && !headless) ||
        accountKey() != pair.account) {
      throw SyncStopped();
    }
  }

  /// The whole-library backup leaves out folders another backup covers.
  Future<void> _skipCoveredFolders(FolderPair pair) async {
    if (access case final LibraryAccess library) {
      library.skipFolders(
        coveredFolders(pair, await journal.pairs(pair.account)),
      );
    }
  }

  /// What a run would do, worked out under the same rules and without changing
  /// anything. It takes no lock and starts no upload service.
  Future<BackupPreview> preview(Account session, FolderPair pair) async {
    await _skipCoveredFolders(pair);
    return SyncEngine(
      client: client,
      access: access,
      journal: journal,
      progress: SyncProgress(),
      check: _check,
      onChanged: () {},
    ).preview(session, pair);
  }

  Future<SyncRunResult> run(Account session, FolderPair pair) async {
    progress.reset();
    String? backgroundReason;
    var locked = false;
    Map<String, dynamic>? state;
    try {
      try {
        locked = await runLock.acquire(pair.account);
        if (!locked) {
          throw StateError('Another manual or scheduled backup is running.');
        }
        await journal.writeState(pair.id, {
          'status': 'running',
          'started': DateTime.now().toUtc().toIso8601String(),
          'finished': null,
          'error': null,
          'transferred': 0,
          'cancel': false,
        });
        await prepareExecution?.call();
        await _skipCoveredFolders(pair);
        final service = backgroundService;
        _backgroundRequested =
            !headless && service != null && await service.permission();
        if (_backgroundRequested) {
          await service!.start((reason) {
            backgroundReason = reason;
            _stop = true;
            onBackgroundPause?.call();
          });
          _backgroundActive = true;
        }
        await SyncEngine(
          client: client,
          access: access,
          journal: journal,
          progress: progress,
          check: _check,
          onChanged: onChanged,
        ).run(session, pair);
        pair.lastRun = DateTime.now();
        await journal.completed(pair.id, pair.lastRun!);
        progress.phase = progress.problems == 0
            ? 'Up to date · no files deleted'
            : 'Done · ${progress.problems} '
                  '${progress.problems == 1 ? 'file' : 'files'} could not be '
                  'backed up';
      } on SyncStopped {
        progress.phase = 'Paused · completed transfers are saved';
        error = backgroundReason;
      } on Object catch (e) {
        final described = describeSyncError(e, phase: progress.phase);
        errorCode = described.code;
        error = described.message;
        progress.phase = 'Needs attention';
      } finally {
        await _stopBackground();
        if (locked) {
          try {
            state = await _settle(pair);
          } finally {
            await runLock.release(pair.account);
          }
        }
      }
    } finally {
      _backgroundActive = _backgroundRequested = false;
    }
    return SyncRunResult(state);
  }

  Future<void> _stopBackground() async {
    if (!_backgroundActive) return;
    try {
      await backgroundService?.stop();
    } on Object catch (e) {
      error ??=
          'Could not stop the upload notification (${e.runtimeType}). '
          'Pause it from Android Settings if it remains visible.';
    }
  }

  /// Records how the run ended and reads the state back.
  Future<Map<String, dynamic>> _settle(FolderPair pair) async {
    // The reason a file could not be backed up, for the first line on screen.
    final firstFailure = progress.problems == 0
        ? null
        : (await journal.failures(pair.id, limit: 1)).firstOrNull?.message;
    await journal.writeState(pair.id, {
      'status': error != null
          ? 'error'
          : _stop
          ? 'paused'
          : progress.problems > 0
          ? 'partial'
          : 'success',
      'phase': progress.phase,
      'error': error,
      'errorCode': errorCode,
      'firstFailure': firstFailure,
      ...progress.toJson(),
      'finished': DateTime.now().toUtc().toIso8601String(),
    });
    return journal.state(pair.id);
  }
}
