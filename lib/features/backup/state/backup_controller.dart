import '../background/backup_scheduler.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../../models.dart';
import '../platform/device_library.dart';
import '../platform/folder_access.dart';
import 'sync_journal.dart';

import '../../../core/cloud/cloud_backend.dart';
import '../model/backup_id.dart';
import '../engine/pair_policy.dart';
import '../engine/backup_preview.dart';
import '../engine/sync_engine.dart';
import '../engine/sync_errors.dart';
import '../engine/sync_runner.dart';
import '../model/sync_rules.dart';
import '../platform/sync_background.dart';
import '../model/backup_schedule.dart';
import '../platform/sync_run_lock.dart';

export '../platform/folder_access.dart';
export '../engine/sync_engine.dart' show SyncProgress, SyncStopped;
export 'sync_journal.dart';

String _key(List<String> path) => jsonEncode(path);

class BackupScheduleFailure extends CloudException {
  const BackupScheduleFailure(this.pair, String message) : super(message);
  final FolderPair pair;
}

/// All transfers create new files. No delete, overwrite, MOVE or PROPPATCH
/// operation exists in this engine. A receipt is committed only after transfer.
class BackupController extends ChangeNotifier {
  BackupController({
    required this.client,
    required this.account,
    FolderAccess? access,
    SyncJournal? journal,
    bool? android,
    bool? ios,
    SyncBackground? backgroundService,
    BackupScheduler? scheduler,
    SyncRunLock? runLock,
    this.prepareExecution,
  }) : access = access ?? NativeFolderAccess(),
       journal = journal ?? SyncJournal(),
       backgroundService = backgroundService ?? NativeSyncBackground(),
       scheduler = scheduler ?? UnsupportedBackupScheduler(),
       runLock =
           runLock ??
           (Platform.isAndroid || Platform.isIOS
               ? NativeSyncRunLock()
               : InProcessSyncRunLock()),
       android = android ?? Platform.isAndroid,
       ios = ios ?? Platform.isIOS;

  final CloudBackend client;
  final Account? Function() account;
  final FolderAccess access;
  final SyncJournal journal;
  final bool android;
  final bool ios;
  final SyncBackground backgroundService;
  final BackupScheduler scheduler;
  final SyncRunLock runLock;
  final Future<void> Function()? prepareExecution;
  final Map<String, Map<String, dynamic>> results = {};
  List<FolderPair> pairs = [];
  String? error;
  String? activeId;
  String? statusPairId;
  final SyncProgress progress = SyncProgress();
  String get phase => progress.phase;
  set phase(String value) => progress.phase = value;
  int get transferred => progress.transferred;
  int get conflicts => progress.conflicts;
  bool _foreground = true;
  SyncRunner? _runner;
  bool _lastRunStopped = false;
  bool _disposed = false;
  Future<void>? _running;
  Future<void>? _loading;
  String? _owner;
  int _sessionGeneration = 0;
  Timer? _albumTimer;
  Future<void>? _automaticTask;
  Future<void>? _batch;
  bool _stopBatch = false;
  final Set<String> queuedIds = {};
  bool get busy =>
      activeId != null ||
      _batch != null ||
      results.values.any((state) => state['status'] == 'running');

  Future<List<DeviceFolder>> photoAlbums() => switch (access) {
    PhotoAlbumAccess source when ios => source.albums(),
    _ => throw UnsupportedError('Apple Photos albums are available on iOS.'),
  };

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    final session = account();
    if (session == null) return;
    final generation = _sessionGeneration;
    if (_owner == syncAccount(session) && error == null) return;
    if (_owner != null && _owner != syncAccount(session)) {
      pairs = [];
      results.clear();
      _owner = null;
      statusPairId = null;
      error = null;
      phase = '';
      _notify();
    }
    var operation = 'read saved folder settings';
    try {
      final saved = await journal.pairs(syncAccount(session));
      if (syncAccount(session) != _accountKey ||
          _disposed ||
          generation != _sessionGeneration) {
        return;
      }
      _owner = _accountKey;
      pairs = saved;
      results.clear();
      operation = 'enable the backup account';
      await journal.enableAccount(syncAccount(session), true);
      for (final pair in pairs) {
        operation = 'read saved backup results';
        results[pair.id] = await journal.state(pair.id);
        operation = 'register backup schedules';
        await _register(pair);
      }
      error = ios
          ? (await journal.state(SyncJournal.iosAlbumService))['error']
                as String?
          : null;
      if (ios && _foreground) {
        _albumTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
          unawaited(checkAutomaticAlbums());
        });
        unawaited(checkAutomaticAlbums());
      }
    } on Object catch (e) {
      _owner = null;
      error = describeLoadError(e, operation: operation);
    }
    _notify();
  }

  String? get _accountKey => account() == null ? null : syncAccount(account()!);

  Future<void> add(
    String name,
    DeviceFolder folder,
    List<String> remote, {
    bool wifiOnly = true,
    SyncRules rules = const SyncRules.all(),
    int uploadConcurrency = 1,
    FolderPair? replacing,
    BackupSchedule? schedule,
  }) async {
    if (busy) {
      throw StateError('Pause the current transfer before editing.');
    }
    final owner = _accountKey;
    if (owner == null || owner != _owner) throw StateError('Reconnect first.');
    if (replacing != null &&
        (replacing.account != owner ||
            !pairs.any((p) => p.id == replacing.id))) {
      throw StateError('This folder configuration is no longer available.');
    }
    validatePair(
      folder: folder,
      remote: remote,
      uploadConcurrency: uploadConcurrency,
      schedule: schedule,
      schedulerSupported: scheduler.supported,
      ios: ios,
      existing: pairs,
      replacing: replacing,
    );
    final samePair =
        replacing != null &&
        replacing.folder.identity == folder.identity &&
        replacing.folder.name == folder.name &&
        _key(replacing.remote) == _key(remote);
    final pair = FolderPair(
      id: samePair ? replacing.id : newBackupId(),
      account: owner,
      name: name.trim().isEmpty ? folder.name : name.trim(),
      folder: folder,
      remote: List.of(remote),
      wifiOnly: wifiOnly,
      rules: rules,
      uploadConcurrency: uploadConcurrency,
      schedule: schedule,
      revision: newBackupId(),
      lastRun: samePair ? replacing.lastRun : null,
    );
    if (!await runLock.acquire(owner)) {
      throw StateError('A backup is running. Pause it and retry editing.');
    }
    try {
      try {
        await journal.save(pair, replacing: replacing);
      } on Object catch (e) {
        error =
            'Could not save backup settings (${e.runtimeType}). Retry saving.';
        statusPairId = null;
        _notify();
        throw CloudException(error!);
      }
      error = null;
      statusPairId = null;
      if (replacing != null) pairs.removeWhere((p) => p.id == replacing.id);
      pairs.add(pair);
      try {
        if (replacing?.schedule != null) {
          await scheduler.cancel(replacing!.id);
        }
        if (schedule != null &&
            android &&
            !await backgroundService.permission(request: true)) {
          throw const CloudException(
            'Allow notifications to enable scheduled backups.',
          );
        }
        await _register(pair);
      } on Object catch (e) {
        error =
            'Backup settings saved, but scheduling failed. '
            '${switch (e) {
              CloudException() => e.message,
              PlatformException() => e.message ?? 'Retry saving (${e.code}).',
              _ => 'Retry saving (${e.runtimeType}).',
            }}';
        _notify();
        throw BackupScheduleFailure(pair, error!);
      }
    } finally {
      await runLock.release(owner);
    }
    _notify();
  }

  Future<void> forget(FolderPair pair) async {
    await pauseAll();
    await journal.writeState(pair.id, {'cancel': true});
    if (!ios && pair.schedule != null) await scheduler.cancel(pair.id);
    if (!await runLock.acquire(pair.account)) {
      throw StateError(
        'Backup is stopping. Retry removing after its current file.',
      );
    }
    try {
      await journal.forget(pair.id);
    } finally {
      await runLock.release(pair.account);
    }
    pairs.removeWhere((value) => value.id == pair.id);
    results.remove(pair.id);
    if (ios && pair.schedule != null) await scheduler.cancel(pair.id);
    _notify();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _albumTimer?.cancel();
      _albumTimer = null;
      if (_runner?.backgroundRequested != true) {
        _runner?.requestStop();
        _stopBatch = true;
      }
    } else {
      unawaited(refreshResults());
      if (ios) {
        _albumTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
          unawaited(checkAutomaticAlbums());
        });
        unawaited(checkAutomaticAlbums());
      }
    }
  }

  Future<void> checkAutomaticAlbums() => _automaticTask ??=
      _checkAutomaticAlbums().whenComplete(() => _automaticTask = null);

  Future<void> _checkAutomaticAlbums() async {
    if (!ios ||
        _disposed ||
        !_foreground ||
        busy ||
        _owner == null ||
        _owner != _accountKey) {
      return;
    }
    final generation = _sessionGeneration;
    try {
      for (final pair in List.of(pairs)) {
        if (_disposed || !_foreground || generation != _sessionGeneration) {
          break;
        }
        if (pair.folder.kind != DeviceSourceKind.photoAlbum ||
            pair.schedule == null) {
          continue;
        }
        final state = await journal.state(pair.id);
        if (_disposed ||
            !_foreground ||
            generation != _sessionGeneration ||
            !pairs.any((p) => p.id == pair.id && p.revision == pair.revision)) {
          break;
        }
        final slot = pair.dueSlot(state, DateTime.now());
        if (slot == null) continue;
        await run(pair);
        if (_disposed || generation != _sessionGeneration) break;
        if (error == null &&
            !_lastRunStopped &&
            results[pair.id]?['status'] == 'success') {
          await journal.writeState(pair.id, {
            'revision': pair.revision,
            'slot': slot,
          });
        }
        if (error == null &&
            !_lastRunStopped &&
            results[pair.id]?['status'] == 'success') {
          await journal.writeState(SyncJournal.iosAlbumService, {
            'error': null,
          });
        }
      }
    } on Object catch (e) {
      if (!_disposed && generation == _sessionGeneration) {
        error = 'Could not check automatic album backups (${e.runtimeType}).';
        _notify();
      }
    }
  }

  Future<void> _register(FolderPair pair) async {
    if (pair.schedule case final schedule?) {
      await scheduler.put(
        pair.id,
        pair.revision,
        schedule,
        wifiOnly: pair.wifiOnly,
      );
    }
  }

  Future<void> pause() async {
    _runner?.requestStop();
    await _running;
  }

  Future<void> runAll() {
    if (busy || _disposed) return Future<void>.value();
    _stopBatch = false;
    final selected = List.of(pairs);
    queuedIds.addAll(selected.map((pair) => pair.id));
    final generation = _sessionGeneration;
    final task = _batch = Future<void>(() async {
      try {
        for (final pair in selected) {
          if (_stopBatch || _disposed || generation != _sessionGeneration) {
            break;
          }
          queuedIds.remove(pair.id);
          try {
            await run(pair);
          } on Object catch (e) {
            results[pair.id] = {
              'status': 'error',
              'error': 'Could not finish backup (${e.runtimeType}). Retry.',
            };
            _notify();
          }
        }
      } finally {
        queuedIds.clear();
        _batch = null;
        _notify();
      }
    });
    _notify();
    return task;
  }

  Future<void> pauseAll() async {
    _stopBatch = true;
    queuedIds.clear();
    await pause();
    await _batch;
    for (final pair in List.of(pairs)) {
      if (results[pair.id]?['status'] == 'running') {
        await pauseScheduled(pair);
      }
    }
  }

  void requestPause() => _runner?.requestStop();

  Future<void> pauseScheduled(FolderPair pair) async {
    await journal.writeState(pair.id, {'cancel': true});
    await refreshResults();
  }

  bool _refreshingResults = false;
  Future<void> refreshResults() async {
    if (_refreshingResults || _disposed) return;
    _refreshingResults = true;
    final generation = _sessionGeneration;
    try {
      for (final pair in List.of(pairs)) {
        var state = await journal.state(pair.id);
        if (_disposed ||
            generation != _sessionGeneration ||
            pair.account != _accountKey) {
          return;
        }
        if (state['status'] == 'running' &&
            activeId != pair.id &&
            await runLock.acquire(pair.account)) {
          try {
            await journal.writeState(pair.id, {
              'status': 'interrupted',
              'error':
                  'The previous backup was interrupted. Completed transfers are saved.',
            });
            state = await journal.state(pair.id);
          } finally {
            await runLock.release(pair.account);
          }
        }
        final saved = await journal.pair(pair.id);
        if (_disposed ||
            generation != _sessionGeneration ||
            pair.account != _accountKey) {
          return;
        }
        results[pair.id] = state;
        pair.lastRun = saved?.lastRun;
      }
      _notify();
    } on Exception catch (e) {
      error = 'Could not read backup results (${e.runtimeType}).';
      _notify();
    } finally {
      _refreshingResults = false;
    }
  }

  Future<void> disconnect() async {
    if (_disposed) return;
    _foreground = false;
    _albumTimer?.cancel();
    _albumTimer = null;
    _sessionGeneration++;
    await _loading;
    final owner = _owner ?? _accountKey;
    if (owner != null) await journal.enableAccount(owner, false);
    await pauseAll();
    await _automaticTask;
    for (final pair
        in owner == null ? <FolderPair>[] : await journal.pairs(owner)) {
      await journal.writeState(pair.id, {'cancel': true});
      if (pair.schedule != null) await scheduler.cancel(pair.id);
    }
    pairs = [];
    results.clear();
    _owner = null;
    statusPairId = null;
    error = null;
    phase = '';
    _notify();
  }

  /// Deletes the account's backup records and any staged transfer files.
  /// Call after [disconnect], while the account is still known.
  Future<void> wipe() async {
    final owner = _owner ?? _accountKey;
    if (owner != null) await journal.clearAccount(owner);
    await access.clearStaging();
  }

  /// Whether this phone can back up its whole photo library, and how much of
  /// it may be read; null where it cannot.
  Future<LibraryPermission?> libraryPermission() async {
    if (access case final LibraryAccess library) {
      return library.libraryPermission();
    }
    return null;
  }

  /// Offers the phone's whole photo and video library as a source, asking for
  /// access if needed. Throws when the user does not allow it.
  Future<DeviceFolder> chooseLibrary() async {
    final library = access;
    if (library is! LibraryAccess) {
      throw const FormatException(
        'Backing up the whole photo library is not available here.',
      );
    }
    final reader = library as LibraryAccess;
    var permission = await reader.libraryPermission();
    if (permission == LibraryPermission.denied) {
      permission = await reader.requestLibraryPermission();
    }
    if (permission == LibraryPermission.denied) {
      throw const FormatException(
        'Allow access to photos and videos to back up your whole library. '
        'You can change this in your phone\'s settings.',
      );
    }
    return const DeviceFolder.library();
  }

  /// What backing up [pair] would do right now, without doing any of it.
  Future<BackupPreview> preview(FolderPair pair) async {
    final session = account();
    if (session == null || syncAccount(session) != pair.account) {
      throw StateError('Sign in to this account to preview its backup.');
    }
    return SyncRunner(
      client: client,
      access: access,
      journal: journal,
      runLock: runLock,
      foreground: () => true,
      accountKey: () => _accountKey,
      onChanged: () {},
    ).preview(session, pair);
  }

  /// The files of [pair] that could not be backed up, with the reasons.
  Future<List<StoredFailure>> failures(FolderPair pair) =>
      journal.failures(pair.id);

  /// Forgets what was uploaded for [pair] and checks every file again. Files
  /// already on the server are recognised by their fingerprint and not uploaded
  /// twice; files missing from it are uploaded. For when the server folder was
  /// emptied or restored, since a backup trusts what it has recorded.
  Future<void> backUpAgain(FolderPair pair) async {
    await journal.resetReceipts(pair.id);
    await run(pair);
  }

  /// Gives every failed file of [pair] a fresh start and runs it again.
  Future<void> retryFailed(FolderPair pair) async {
    await journal.resetFailures(pair.id);
    await run(pair);
  }

  /// Runs one pair now, in the foreground.
  Future<void> run(FolderPair pair) async {
    if (_running != null || _disposed || !_foreground) return;
    final session = account();
    if (session == null || syncAccount(session) != pair.account) return;
    final runner = _runner = SyncRunner(
      client: client,
      access: access,
      journal: journal,
      runLock: runLock,
      backgroundService: android ? backgroundService : null,
      foreground: () => _foreground,
      accountKey: () => _accountKey,
      onChanged: _notify,
      progress: progress,
      prepareExecution: prepareExecution,
      onBackgroundPause: () => _stopBatch = true,
    );
    activeId = pair.id;
    statusPairId = pair.id;
    error = null;
    final finished = Completer<void>();
    _running = finished.future;
    _notify();
    try {
      final result = await runner.run(session, pair);
      if (result.state != null) {
        results[pair.id] = result.state!;
      } else if (runner.error != null) {
        results[pair.id] = {'status': 'error', 'error': runner.error};
      }
    } finally {
      error = runner.error;
      _lastRunStopped = runner.stopRequested;
      _runner = null;
      activeId = null;
      _running = null;
      finished.complete();
      _notify();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _runner?.requestStop();
    _stopBatch = true;
    _albumTimer?.cancel();
    unawaited(
      (_running ?? Future<void>.value()).then((_) async {
        await _loading;
        await _automaticTask;
        await _batch;
        await journal.close();
      }, onError: (Object _, StackTrace _) => journal.close()),
    );
    super.dispose();
  }
}
