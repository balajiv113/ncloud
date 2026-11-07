import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../../models.dart';
import 'folder_access.dart';
import 'sync_journal.dart';

import '../../core/cloud/cloud_backend.dart';
import 'sync_rules.dart';
import 'sync_background.dart';
import 'sync_schedule.dart';
import 'sync_run_lock.dart';

export 'folder_access.dart';
export 'sync_journal.dart';

String _key(List<String> path) => jsonEncode(path);
String _id() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

class SyncStopped implements Exception {}

class BackupScheduleFailure extends CloudException {
  const BackupScheduleFailure(this.pair, String message) : super(message);
  final FolderPair pair;
}

/// All transfers create new files. No delete, overwrite, MOVE or PROPPATCH
/// operation exists in this engine. A receipt is committed only after transfer.
class FolderSyncController extends ChangeNotifier {
  FolderSyncController({
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
  String phase = '';
  int transferred = 0;
  int conflicts = 0;
  bool _foreground = true;
  bool _backgroundActive = false;
  bool _headlessActive = false;
  bool _backgroundRequested = false;
  bool _stop = false;
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
      final detail = switch (e) {
        DatabaseException() =>
          'Database error ${e.getResultCode() ?? 'unknown'}. Saved folders and receipts have not been reset.',
        MissingPluginException() =>
          'The native backup service is unavailable. Fully close ncloud and install the latest build.',
        PlatformException() when e.code == 'backup_schedule' =>
          e.message ?? 'iOS could not register background backup.',
        PlatformException() => 'Device service error (${e.code}).',
        FormatException() => e.message,
        _ => 'Operation failed (${e.runtimeType}).',
      };
      error = 'Could not $operation. $detail Retry loading folder settings.';
    }
    _notify();
  }

  String? get _accountKey => account() == null ? null : syncAccount(account()!);

  void _validateRules(SyncRules rules, int concurrency) {
    if (concurrency < 1 || concurrency > 3) {
      throw const FormatException('Use 1 to 3 uploads.');
    }
  }

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
    checkSyncPath(remote);
    checkSyncPath([folder.name]);
    if (replacing != null &&
        (replacing.account != owner ||
            !pairs.any((p) => p.id == replacing.id))) {
      throw StateError('This folder configuration is no longer available.');
    }
    _validateRules(rules, uploadConcurrency);
    if (folder.kind == DeviceSourceKind.photoAlbum && !ios) {
      throw const FormatException(
        'Apple Photos albums support upload-only backup on iOS.',
      );
    }
    if (schedule != null && !scheduler.supported) {
      throw const FormatException(
        'Scheduled backups require a supported upload-only source.',
      );
    }
    if (schedule != null && ios && folder.kind != DeviceSourceKind.photoAlbum) {
      throw const FormatException(
        'iOS background backups currently support Apple Photos albums only.',
      );
    }
    bool overlaps(List<String> a, List<String> b) =>
        a.length <= b.length &&
        List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
    final cloudRoot = [...remote, folder.name];
    if (pairs.any(
      (pair) =>
          pair.id != replacing?.id &&
          (pair.folder.identity == folder.identity ||
              overlaps(pair.cloudRoot, cloudRoot) ||
              overlaps(cloudRoot, pair.cloudRoot)),
    )) {
      throw const FormatException(
        'Choose a different device folder and a non-overlapping cloud folder.',
      );
    }
    final samePair =
        replacing != null &&
        replacing.folder.identity == folder.identity &&
        replacing.folder.name == folder.name &&
        _key(replacing.remote) == _key(remote);
    final pair = FolderPair(
      id: samePair ? replacing.id : _id(),
      account: owner,
      name: name.trim().isEmpty ? folder.name : name.trim(),
      folder: folder,
      remote: List.of(remote),
      wifiOnly: wifiOnly,
      rules: rules,
      uploadConcurrency: uploadConcurrency,
      schedule: schedule,
      revision: _id(),
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
      if (!_backgroundRequested) {
        _stop = true;
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
        final slot = pair.schedule!.dueSlot(DateTime.now());
        final state = await journal.state(pair.id);
        if (_disposed ||
            !_foreground ||
            generation != _sessionGeneration ||
            !pairs.any((p) => p.id == pair.id && p.revision == pair.revision)) {
          break;
        }
        if (slot == null ||
            (state['revision'] == pair.revision &&
                pair.schedule!.handled(slot, state['slot'] as String?))) {
          continue;
        }
        await run(pair);
        if (_disposed || generation != _sessionGeneration) break;
        if (error == null &&
            !_stop &&
            results[pair.id]?['status'] == 'success') {
          await journal.writeState(pair.id, {
            'revision': pair.revision,
            'slot': slot,
          });
        }
        if (error == null &&
            !_stop &&
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
    _stop = true;
    await _running;
  }

  Future<void> runAll() {
    if (busy || _disposed) return Future<void>.value();
    _stopBatch = false;
    final selected = pairs.where((pair) => !pair.requiresSetup).toList();
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

  void requestPause() {
    _stop = true;
  }

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

  Future<void> run(FolderPair pair, {bool headless = false}) async {
    if (_running != null || _disposed || (!_foreground && !headless)) return;
    final session = account();
    if (session == null || syncAccount(session) != pair.account) return;
    _stop = false;
    _headlessActive = headless;
    _backgroundRequested = false;
    activeId = pair.id;
    statusPairId = pair.id;
    error = null;
    transferred = conflicts = 0;
    String? backgroundReason;
    String? errorCode;
    var locked = false;
    final finished = Completer<void>();
    _running = finished.future;
    _notify();
    final task = () async {
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
      _backgroundRequested =
          !headless && android && await backgroundService.permission();
      if (_backgroundRequested) {
        await backgroundService.start((reason) {
          backgroundReason = reason;
          _stop = true;
          _stopBatch = true;
        });
        _backgroundActive = true;
      }
      await _sync(session, pair);
    }();
    try {
      await task;
      pair.lastRun = DateTime.now();
      await journal.completed(pair.id, pair.lastRun!);
      phase = 'Up to date · no files deleted';
    } on SyncStopped {
      phase = 'Paused · completed transfers are saved';
      error = backgroundReason;
    } on Object catch (e) {
      errorCode = e is PlatformException ? e.code : null;
      error = switch (e) {
        CloudException() => e.message,
        StateError() => e.message.toString(),
        FormatException() => e.message,
        MissingPluginException() =>
          'The native folder-sync service is unavailable. Install the latest ncloud build '
              'and fully restart the app. Reconnecting the folder will not fix this.',
        PlatformException() => switch (e.code) {
          'photos_permission' ||
          'photos_changed' ||
          'photos_album' ||
          'photos_timeout' ||
          'photos_cancelled' ||
          'photos_unavailable' ||
          'photos_export' ||
          'backup_schedule' =>
            e.message ?? 'Photos album backup needs attention (${e.code}).',
          'folder_permission' =>
            'Access to the selected folder was denied. Reselect the source.',
          'folder_unavailable' =>
            'The selected folder or file is unavailable. Check its Files provider '
                'or connected device, then retry.',
          'folder_io' =>
            'The folder provider could not read or write the transfer. '
                'Check device space and whether the file is available offline.',
          'conditions_permission' =>
            'Android could not check Wi-Fi/charging conditions. '
                'Update ncloud and retry; folder permission is unchanged.',
          'background_permission' =>
            'Allow ncloud notifications in device Settings and retry.',
          'background_start' =>
            'Android could not start the upload service. Open ncloud and retry.',
          'scheduled_background' =>
            'Android could not show the scheduled backup notification. '
                'Allow Scheduled folder backups notifications and background activity in device Settings.',
          _ =>
            'The device folder operation failed (${e.code}). '
                'Existing files were not overwritten. Check the selected folder provider.',
        },
        DatabaseException() =>
          'Could not save sync progress (SQLite ${e.getResultCode() ?? 'unknown'}). '
              'Check device storage. Completed transfers may be copied again on retry.',
        FileSystemException() =>
          'Could not access a temporary transfer file. Check free device space.',
        SocketException() =>
          'The connection was interrupted. Retry when connected.',
        TimeoutException() => 'The transfer timed out. Retry when connected.',
        _ =>
          'Sync failed (${e.runtimeType}) during $phase. '
              'Existing files were not overwritten.',
      };
      phase = 'Needs attention';
    } finally {
      if (_backgroundActive) {
        try {
          await backgroundService.stop();
        } on Object catch (e) {
          error ??=
              'Could not stop the upload notification (${e.runtimeType}). '
              'Pause it from Android Settings if it remains visible.';
        }
      }
      _backgroundActive = _backgroundRequested = false;
      _headlessActive = false;
      try {
        if (locked) {
          try {
            await journal.writeState(pair.id, {
              'status': error != null
                  ? 'error'
                  : _stop
                  ? 'paused'
                  : 'success',
              'phase': phase,
              'error': error,
              'errorCode': errorCode,
              'transferred': transferred,
              'finished': DateTime.now().toUtc().toIso8601String(),
            });
            results[pair.id] = await journal.state(pair.id);
          } finally {
            await runLock.release(pair.account);
          }
        }
      } finally {
        if (!locked && error != null) {
          results[pair.id] = {'status': 'error', 'error': error};
        }
        activeId = null;
        _running = null;
        finished.complete();
        _notify();
      }
    }
  }

  void _check(FolderPair pair) {
    if (_stop ||
        _disposed ||
        (!_foreground && !_backgroundActive && !_headlessActive) ||
        _accountKey != pair.account) {
      throw SyncStopped();
    }
  }

  String _remoteVersion(CloudFile file) {
    if (file.etag?.isNotEmpty != true) {
      throw const FormatException(
        'The server did not supply a file revision. Sync stopped safely.',
      );
    }
    return '${file.etag}|${file.size}';
  }

  List<String> _target(Map<String, Object?> receipt) =>
      (jsonDecode(receipt['target'] as String) as List).cast<String>();

  List<String> _conflict(List<String> path, String direction) {
    conflicts++;
    final name = path.last;
    final dot = name.lastIndexOf('.');
    final split = dot > 0 ? dot : name.length;
    // Keep room for the suffix on common filesystems, counting UTF-8 bytes.
    var stem = name.substring(0, split);
    final extension = name.substring(split);
    if (utf8.encode(extension).length > 32) {
      throw const FormatException(
        'File extension is too long to preserve safely.',
      );
    }
    while (utf8.encode(stem).length > 140) {
      stem = String.fromCharCodes(stem.runes.take(stem.runes.length - 1));
    }
    return [
      ...path.take(path.length - 1),
      '$stem (ncloud $direction ${_id().substring(0, 12)})$extension',
    ];
  }

  Future<void> _sync(Account session, FolderPair pair) async {
    final source = access;
    _check(pair);
    if (pair.requiresSetup) {
      throw const FormatException(
        'Edit this source to configure an upload backup.',
      );
    }
    final album = pair.folder.kind == DeviceSourceKind.photoAlbum;
    checkSyncPath(pair.cloudRoot);
    _validateRules(pair.rules, pair.uploadConcurrency);
    phase = 'Checking Wi-Fi';
    _notify();
    await _conditions(pair);
    final local = <String, (List<String>, DeviceEntry)>{};
    final remote = <String, (List<String>, CloudFile)>{};
    final directories = <List<String>>[[]];
    var scanned = 0;
    phase = 'Reading selected device folder';
    _notify();
    // A complete, successful inventory precedes transfers; a permission error
    // must not be interpreted as an empty source or a deletion.
    while (directories.isNotEmpty) {
      _check(pair);
      if (++scanned > 100000) {
        throw const FormatException(
          'This pair exceeds the supported scan size.',
        );
      }
      final path = directories.removeLast();
      for (final item in await source.list(pair.folder.token, path)) {
        final child = [...path, item.name];
        checkSyncPath(child);
        if (child.length > 64 || local.length > 100000) {
          throw const FormatException(
            'This pair exceeds the supported scan size.',
          );
        }
        if (item.directory) {
          if (pair.rules.visits(child)) {
            directories.add(child);
          }
        } else {
          if (!pair.rules.allows(child, contentType: item.contentType)) {
            continue;
          }
          if (item.modified <= 0 ||
              (item.size < 0 &&
                  !(album &&
                      item.size == -1 &&
                      item.revision?.isNotEmpty == true))) {
            throw const FormatException(
              'The folder provider supplies no file modification date.',
            );
          }
          local[_key(child)] = (child, item);
        }
      }
    }
    directories.add([]);
    phase = 'Reading cloud destination';
    _notify();
    {
      final children = (await client.listFolder(session, pair.remote)).children;
      _check(pair);
      final folder = children
          .where((file) => file.name == pair.folder.name)
          .singleOrNull;
      if (folder == null) {
        await client.createFolder(session, pair.cloudRoot);
      } else if (!folder.isDirectory) {
        throw const FormatException(
          'A file blocks the selected folder name on the server. Choose another destination.',
        );
      }
    }
    while (directories.isNotEmpty) {
      _check(pair);
      if (++scanned > 200000) {
        throw const FormatException(
          'This pair exceeds the supported scan size.',
        );
      }
      final path = directories.removeLast();
      for (final item in (await client.listFolder(session, [
        ...pair.cloudRoot,
        ...path,
      ])).children) {
        // Never follow a server listing outside the requested direct children.
        final expected = [...pair.cloudRoot, ...path, item.name];
        checkSyncPath(expected);
        if (_key(expected) != _key(item.path) || item.albumReference != null) {
          throw const FormatException(
            'The server returned an unexpected file path.',
          );
        }
        final child = [...path, item.name];
        if (child.length > 64 || remote.length > 100000) {
          throw const FormatException(
            'This pair exceeds the supported scan size.',
          );
        }
        if (item.isDirectory) {
          if (pair.rules.visits(child)) directories.add(child);
        } else {
          if (!pair.rules.allows(child, contentType: item.contentType)) {
            continue;
          }
          _remoteVersion(item);
          remote[_key(child)] = (child, item);
        }
      }
    }
    {
      final pending = local.values.toList();
      final reserved = <String>{};
      var directoryTail = Future<void>.value();
      Future<void> prepare(List<String> target) async {
        final previous = directoryTail;
        final ready = Completer<void>();
        directoryTail = ready.future;
        try {
          await previous;
          await _ensureRemote(session, pair, target);
        } finally {
          ready.complete();
        }
      }

      Future<void> upload((List<String>, DeviceEntry) entry) async {
        final (path, file) = entry;
        _check(pair);
        final receipt = await journal.receipt(pair.id, 'local', path);
        if (receipt != null && receipt['version'] == file.version) {
          final target = remote[_key(_target(receipt))];
          if (target != null &&
              _remoteVersion(target.$2) == receipt['target_version']) {
            return;
          }
        }
        var target = path;
        while (remote.containsKey(_key(target)) ||
            reserved.contains(_key(target))) {
          target = _conflict(target, 'device');
        }
        reserved.add(_key(target));
        await _conditions(pair);
        phase = 'Uploading ${file.name}';
        _notify();
        File? staged;
        try {
          staged = await source.export(pair.folder.token, path, file);
          _check(pair);
          final stagedSize = await staged.length();
          if (file.size >= 0 && stagedSize != file.size) {
            throw const FormatException(
              'The source changed while preparing it. Run again.',
            );
          }
          await prepare(target);
          _check(pair);
          await _conditions(pair);
          await client.uploadNew(
            session,
            [...pair.cloudRoot, ...target],
            staged.openRead(),
            stagedSize,
          );
          final confirmed =
              (await client.listFolder(session, [
                    ...pair.cloudRoot,
                    ...target.take(target.length - 1),
                  ])).children
                  .where(
                    (item) => item.name == target.last && !item.isDirectory,
                  )
                  .single;
          if (confirmed.size != stagedSize) {
            throw const FormatException(
              'Upload size was not confirmed. Run again to reconcile.',
            );
          }
          final version = _remoteVersion(confirmed);
          await journal.confirm(pair.id, path, file.version, target, version);
          remote[_key(target)] = (target, confirmed);
          transferred++;
          await journal.writeState(pair.id, {
            'transferred': transferred,
            'phase': phase,
          });
          _notify();
        } finally {
          if (staged != null) await source.discard(staged);
        }
      }

      var index = 0;
      Object? failure;
      StackTrace? failureStack;
      Future<void> worker() async {
        while (failure == null && index < pending.length) {
          final entry = pending[index++];
          try {
            await upload(entry);
          } on Object catch (e, stack) {
            if (failure == null || failure is SyncStopped) {
              failure = e;
              failureStack = stack;
            }
          }
        }
      }

      await Future.wait(List.generate(pair.uploadConcurrency, (_) => worker()));
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    }
    _check(pair);
  }

  Future<void> _conditions(FolderPair pair) async {
    _check(pair);
    if (!pair.wifiOnly) return;
    final conditions = await access.conditions();
    if (pair.wifiOnly && !conditions.wifi) {
      throw const FormatException('Waiting for Wi-Fi. Connect and retry.');
    }
  }

  Future<void> _ensureRemote(
    Account session,
    FolderPair pair,
    List<String> target,
  ) async {
    var parent = List.of(pair.cloudRoot);
    for (final segment in target.take(target.length - 1)) {
      _check(pair);
      final children = (await client.listFolder(session, parent)).children;
      _check(pair);
      final match = children.where((file) => file.name == segment).singleOrNull;
      parent = [...parent, segment];
      if (match == null) {
        await client.createFolder(session, parent);
      } else if (!match.isDirectory) {
        throw const FormatException(
          'A file blocks a destination folder. Choose another destination.',
        );
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stop = true;
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
