import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'cloud_backend.dart';
import 'sync_rules.dart';
import 'sync_background.dart';
import 'sync_schedule.dart';
import 'sync_run_lock.dart';

enum SyncMode { backup, download, merge }

extension SyncModeLabel on SyncMode {
  String get label => switch (this) {
    SyncMode.backup => 'Backup · device → cloud',
    SyncMode.download => 'Download · cloud → device',
    SyncMode.merge => 'Two-way · keep both',
  };
}

String syncAccount(Account account) => '${account.server}|${account.userId}';
String _key(List<String> path) => jsonEncode(path);
String _id() => List.generate(
  16,
  (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

void checkSyncPath(List<String> path) {
  for (final name in path) {
    if (name.isEmpty ||
        name == '.' ||
        name == '..' ||
        name.contains(RegExp(r'[/\\\x00-\x1f]'))) {
      throw const FormatException('Unsupported name in the selected folder.');
    }
  }
}

enum DeviceSourceKind { folder, photoAlbum }

class DeviceFolder {
  const DeviceFolder(
    this.token,
    this.name,
    this.identity, {
    this.kind = DeviceSourceKind.folder,
  });
  final String token;
  final String name;
  final String identity;
  final DeviceSourceKind kind;
}

class DeviceEntry {
  const DeviceEntry(
    this.name,
    this.directory,
    this.size,
    this.modified, {
    this.contentType = '',
    this.revision,
  });
  final String name;
  final bool directory;
  final int size;
  final int modified;
  final String contentType;
  final String? revision;
  String get version => revision ?? '$size|$modified';
}

class SyncConditions {
  const SyncConditions({required this.wifi, required this.charging});
  final bool wifi;
  final bool charging;
}

abstract interface class FolderAccess {
  Future<DeviceFolder?> pick();
  Future<List<DeviceEntry>> list(String token, List<String> path);
  Future<File> export(String token, List<String> path, DeviceEntry expected);
  Future<File> stage();
  Future<DeviceEntry> import(String token, List<String> path, File staged);
  Future<void> discard(File staged);
  Future<SyncConditions> conditions();
}

abstract interface class PhotoAlbumAccess {
  Future<List<DeviceFolder>> albums();
}

class NativeFolderAccess implements FolderAccess, PhotoAlbumAccess {
  static const channel = MethodChannel('app.ncloud/folder_sync');

  @override
  Future<List<DeviceFolder>> albums() async {
    final values = await channel.invokeListMethod<dynamic>('albums');
    if (values == null) throw StateError('Photos returned no album listing.');
    return [
      for (final value in values)
        DeviceFolder(
          value['token'] as String,
          value['name'] as String,
          value['identity'] as String,
          kind: DeviceSourceKind.photoAlbum,
        ),
    ];
  }

  Future<void> requireWorkerNotification(int id) async {
    for (var attempt = 0; attempt < 20; attempt++) {
      if (await channel.invokeMethod<bool>('workerNotification', {'id': id}) ==
          true) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw PlatformException(
      code: 'scheduled_background',
      message: 'Scheduled backup foreground notification is unavailable.',
    );
  }

  @override
  Future<SyncConditions> conditions() async {
    final value = await channel.invokeMapMethod<String, dynamic>('conditions');
    return SyncConditions(
      wifi: value?['wifi'] == true,
      charging: value?['charging'] == true,
    );
  }

  @override
  Future<DeviceFolder?> pick() async {
    final value = await channel.invokeMapMethod<String, dynamic>('pick');
    return value == null
        ? null
        : DeviceFolder(
            value['token'] as String,
            value['name'] as String,
            value['identity'] as String,
          );
  }

  DeviceEntry _entry(Map<dynamic, dynamic> value) => DeviceEntry(
    value['name'] as String,
    value['directory'] as bool,
    value['size'] as int,
    value['modified'] as int,
    contentType: value['contentType'] as String? ?? '',
    revision: value['revision'] as String?,
  );

  @override
  Future<List<DeviceEntry>> list(String token, List<String> path) async {
    checkSyncPath(path);
    final values = await channel.invokeListMethod<dynamic>('list', {
      'token': token,
      'path': path,
    });
    if (values == null) {
      throw StateError('Folder provider returned no listing.');
    }
    return [for (final value in values) _entry(value as Map<dynamic, dynamic>)];
  }

  @override
  Future<File> export(
    String token,
    List<String> path,
    DeviceEntry expected,
  ) async {
    checkSyncPath(path);
    final file = await channel.invokeMethod<String>('export', {
      'token': token,
      'path': path,
      'size': expected.size,
      'modified': expected.modified,
      'version': expected.version,
    });
    if (file == null) throw StateError('Could not prepare the source file.');
    return File(file);
  }

  @override
  Future<File> stage() async {
    final path = await channel.invokeMethod<String>('stage');
    if (path == null) throw StateError('Could not prepare a transfer file.');
    return File(path);
  }

  @override
  Future<DeviceEntry> import(
    String token,
    List<String> path,
    File staged,
  ) async {
    checkSyncPath(path);
    final value = await channel.invokeMapMethod<String, dynamic>('import', {
      'token': token,
      'path': path,
      'staged': staged.path,
    });
    if (value == null) throw StateError('Could not confirm the saved file.');
    return _entry(value);
  }

  @override
  Future<void> discard(File staged) =>
      channel.invokeMethod<void>('discard', {'staged': staged.path});
}

class FolderPair {
  FolderPair({
    required this.id,
    required this.account,
    required this.name,
    required this.folder,
    required this.remote,
    required this.mode,
    this.repeat = false,
    this.wifiOnly = true,
    this.chargingOnly = false,
    this.lastRun,
    this.rules = const SyncRules.all(),
    this.uploadConcurrency = 1,
    this.background = false,
    this.schedule,
    this.revision = '',
  });
  final String id;
  final String account;
  final String name;
  final DeviceFolder folder;
  final List<String> remote;
  final SyncMode mode;
  bool repeat;
  final bool wifiOnly;
  final bool chargingOnly;
  DateTime? lastRun;
  final SyncRules rules;
  final int uploadConcurrency;
  final bool background;
  final BackupSchedule? schedule;
  final String revision;

  bool get includesSourceFolder => mode != SyncMode.download;

  List<String> get cloudRoot => [
    ...remote,
    if (includesSourceFolder) folder.name,
  ];

  Map<String, Object?> toJson() => {
    'id': id,
    'account': account,
    'name': name,
    'token': folder.token,
    'folderName': folder.name,
    'identity': folder.identity,
    'sourceKind': folder.kind.name,
    'remote': remote,
    'mode': mode.name,
    'repeat': repeat,
    'wifiOnly': wifiOnly,
    'chargingOnly': chargingOnly,
    'lastRun': lastRun?.toIso8601String(),
    'rules': rules.toJson(),
    'uploadConcurrency': uploadConcurrency,
    'background': background,
    'schedule': schedule?.toJson(),
    'revision': revision,
  };

  factory FolderPair.fromJson(Map<String, dynamic> value) => FolderPair(
    id: value['id'] as String,
    account: value['account'] as String,
    name: value['name'] as String,
    folder: DeviceFolder(
      value['token'] as String,
      value['folderName'] as String,
      value['identity'] as String,
      kind: DeviceSourceKind.values.byName(
        value['sourceKind'] as String? ?? DeviceSourceKind.folder.name,
      ),
    ),
    remote: (value['remote'] as List).cast<String>(),
    mode: SyncMode.values.byName(value['mode'] as String),
    repeat: value['repeat'] as bool,
    wifiOnly: value['wifiOnly'] as bool,
    chargingOnly: value['chargingOnly'] as bool,
    lastRun: DateTime.tryParse(value['lastRun'] as String? ?? ''),
    rules: SyncRules.fromJson((value['rules'] as Map).cast<String, dynamic>()),
    uploadConcurrency: value['uploadConcurrency'] as int,
    background: value['background'] as bool,
    schedule: value['schedule'] == null
        ? null
        : BackupSchedule.fromJson(
            (value['schedule'] as Map).cast<String, dynamic>(),
          ),
    revision: value['revision'] as String? ?? '',
  );
}

class SyncJournal {
  static const iosAlbumService = 'ios-album-service';
  SyncJournal({this.path, this.factory});
  final String? path;
  final DatabaseFactory? factory;
  Database? _database;
  Future<Database>? _opening;

  Future<Database> get db =>
      _opening ??= _open().whenComplete(() => _opening = null);

  Future<Database> _open() async {
    if (_database != null) return _database!;
    final location =
        path ??
        '${(await getApplicationSupportDirectory()).path}/folder-sync.sqlite3';
    await Directory(File(location).parent.path).create(recursive: true);
    return _database = await (factory ?? databaseFactory).openDatabase(
      location,
      options: OpenDatabaseOptions(
        version: 2,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA busy_timeout=5000');
          await db.rawQuery('PRAGMA journal_mode=WAL');
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) await _createScheduleTables(db);
        },
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE pairs (id TEXT PRIMARY KEY, account TEXT NOT NULL, '
            'payload TEXT NOT NULL)',
          );
          await _createScheduleTables(db);
          await db.execute(
            'CREATE TABLE receipts (pair TEXT NOT NULL, side TEXT NOT NULL, '
            'path TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, '
            'target_version TEXT NOT NULL, PRIMARY KEY(pair,side,path))',
          );
        },
      ),
    );
  }

  static Future<void> _createScheduleTables(Database db) async {
    await db.execute(
      'CREATE TABLE run_state (pair TEXT PRIMARY KEY, payload TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE sync_sessions (account TEXT PRIMARY KEY, enabled INTEGER NOT NULL)',
    );
  }

  Future<void> enableAccount(String account, bool enabled) async =>
      (await db).insert('sync_sessions', {
        'account': account,
        'enabled': enabled ? 1 : 0,
      }, conflictAlgorithm: ConflictAlgorithm.replace);

  Future<bool> accountEnabled(String account) async => (await (await db).query(
    'sync_sessions',
    where: 'account=? AND enabled=1',
    whereArgs: [account],
  )).isNotEmpty;

  Future<FolderPair?> pair(String id) async {
    final rows = await (await db).query(
      'pairs',
      where: 'id=?',
      whereArgs: [id],
    );
    return rows.isEmpty
        ? null
        : FolderPair.fromJson(
            (jsonDecode(rows.single['payload'] as String) as Map)
                .cast<String, dynamic>(),
          );
  }

  Future<Map<String, dynamic>> state(String id) async {
    final rows = await (await db).query(
      'run_state',
      where: 'pair=?',
      whereArgs: [id],
    );
    return rows.isEmpty
        ? {}
        : (jsonDecode(rows.single['payload'] as String) as Map)
              .cast<String, dynamic>();
  }

  Future<void> writeState(String id, Map<String, dynamic> changes) async =>
      (await db).transaction((txn) async {
        final rows = await txn.query(
          'run_state',
          where: 'pair=?',
          whereArgs: [id],
        );
        final old = rows.isEmpty
            ? <String, dynamic>{}
            : (jsonDecode(rows.single['payload'] as String) as Map)
                  .cast<String, dynamic>();
        await txn.insert('run_state', {
          'pair': id,
          'payload': jsonEncode({...old, ...changes}),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      });

  Future<void> completed(String id, DateTime time) async =>
      (await db).transaction((txn) async {
        final rows = await txn.query('pairs', where: 'id=?', whereArgs: [id]);
        if (rows.isEmpty) return;
        final payload = (jsonDecode(rows.single['payload'] as String) as Map)
            .cast<String, dynamic>();
        payload['lastRun'] = time.toIso8601String();
        await txn.update(
          'pairs',
          {'payload': jsonEncode(payload)},
          where: 'id=?',
          whereArgs: [id],
        );
      });

  Future<List<FolderPair>> pairs(String account) async {
    final result = <FolderPair>[];
    for (final row in await (await db).query(
      'pairs',
      where: 'account=?',
      whereArgs: [account],
    )) {
      final payload = (jsonDecode(row['payload'] as String) as Map)
          .cast<String, dynamic>();
      if (payload['photoBackup'] == true) {
        await forget(row['id'] as String);
      } else {
        result.add(FolderPair.fromJson(payload));
      }
    }
    return result;
  }

  Future<void> save(FolderPair pair, {FolderPair? replacing}) async =>
      (await db).transaction((txn) async {
        await txn.insert('pairs', {
          'id': pair.id,
          'account': pair.account,
          'payload': jsonEncode(pair.toJson()),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
        if (replacing != null && replacing.id != pair.id) {
          await txn.delete(
            'receipts',
            where: 'pair=?',
            whereArgs: [replacing.id],
          );
          await txn.delete('pairs', where: 'id=?', whereArgs: [replacing.id]);
        }
      });

  Future<Map<String, Object?>?> receipt(
    String pair,
    String side,
    List<String> path,
  ) async {
    final rows = await (await db).query(
      'receipts',
      where: 'pair=? AND side=? AND path=?',
      whereArgs: [pair, side, _key(path)],
    );
    return rows.singleOrNull;
  }

  Future<void> confirm(
    String pair,
    List<String> local,
    String localVersion,
    List<String> remote,
    String remoteVersion,
  ) async => (await db).transaction((txn) async {
    for (final (side, path, version, target, targetVersion) in [
      ('local', local, localVersion, remote, remoteVersion),
      ('remote', remote, remoteVersion, local, localVersion),
    ]) {
      await txn.insert('receipts', {
        'pair': pair,
        'side': side,
        'path': _key(path),
        'version': version,
        'target': _key(target),
        'target_version': targetVersion,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
  });

  Future<void> forget(String id) async => (await db).transaction((txn) async {
    await txn.delete('run_state', where: 'pair=?', whereArgs: [id]);
    await txn.delete('receipts', where: 'pair=?', whereArgs: [id]);
    await txn.delete('pairs', where: 'id=?', whereArgs: [id]);
  });

  Future<void> close() async {
    await _opening;
    await _database?.close();
    _database = null;
  }
}

class SyncStopped implements Exception {}

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
    if (_owner == syncAccount(session)) return;
    if (_owner != null && _owner != syncAccount(session)) {
      pairs = [];
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
        unawaited(checkAutomaticAlbums(force: true));
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
        FormatException() => 'The saved folder settings contain invalid data.',
        _ => 'Operation failed (${e.runtimeType}).',
      };
      error = 'Could not $operation. $detail Retry loading folder settings.';
    }
    _notify();
  }

  String? get _accountKey => account() == null ? null : syncAccount(account()!);

  void _validateRules(SyncRules rules, int concurrency) {
    if (rules.included.isEmpty ||
        rules.included.length + rules.excluded.length > 1000 ||
        concurrency < 1 ||
        concurrency > 3) {
      throw const FormatException(
        'Choose included folders and 1 to 3 uploads.',
      );
    }
    for (final path in [...rules.included, ...rules.excluded]) {
      checkSyncPath(path);
      if (path.length > 64) {
        throw const FormatException('Folder path is too deep.');
      }
    }
  }

  Future<void> add(
    String name,
    DeviceFolder folder,
    List<String> remote,
    SyncMode mode,
    bool repeat, {
    bool wifiOnly = true,
    bool chargingOnly = false,
    SyncRules rules = const SyncRules.all(),
    int uploadConcurrency = 1,
    bool background = false,
    FolderPair? replacing,
    BackupSchedule? schedule,
  }) async {
    if (_running != null) {
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
    if (folder.kind == DeviceSourceKind.photoAlbum &&
        (!ios || mode != SyncMode.backup)) {
      throw const FormatException(
        'Apple Photos albums support upload-only backup on iOS.',
      );
    }
    if (schedule != null && (!scheduler.supported || mode != SyncMode.backup)) {
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
    final cloudRoot = [...remote, if (mode != SyncMode.download) folder.name];
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
        _key(replacing.remote) == _key(remote) &&
        replacing.mode == mode;
    final pair = FolderPair(
      id: samePair ? replacing.id : _id(),
      account: owner,
      name: name.trim().isEmpty ? folder.name : name.trim(),
      folder: folder,
      remote: List.of(remote),
      mode: mode,
      repeat: android && repeat,
      wifiOnly: wifiOnly,
      chargingOnly: chargingOnly,
      rules: rules,
      uploadConcurrency: uploadConcurrency,
      background: android && background,
      schedule: schedule,
      revision: _id(),
      lastRun: samePair ? replacing.lastRun : null,
    );
    if (!await runLock.acquire(owner)) {
      throw StateError('A backup is running. Pause it and retry editing.');
    }
    try {
      await journal.save(pair, replacing: replacing);
      if (replacing != null) pairs.removeWhere((p) => p.id == replacing.id);
      pairs.add(pair);
      _notify();
      if (replacing != null) await scheduler.cancel(replacing.id);
      await _register(pair);
    } on Exception catch (e) {
      _owner = null;
      error =
          'Schedule registration failed (${e.runtimeType}). Settings are saved; reopen Folder sync to retry.';
      _notify();
      rethrow;
    } finally {
      await runLock.release(owner);
    }
    _notify();
    if (ios && pair.folder.kind == DeviceSourceKind.photoAlbum) {
      unawaited(checkAutomaticAlbums(force: true));
    }
  }

  Future<void> forget(FolderPair pair) async {
    await pause();
    await journal.writeState(pair.id, {'cancel': true});
    await scheduler.cancel(pair.id);
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
    if (ios) await scheduler.cancel(pair.id);
    _notify();
  }

  Future<void> reconnect(FolderPair pair) async {
    if (_running != null || _accountKey != pair.account) return;
    if (pair.folder.kind == DeviceSourceKind.photoAlbum) {
      throw const FormatException(
        'Allow full Photos access in iOS Settings. To change the album, edit this pair.',
      );
    }
    final folder = await access.pick();
    if (folder == null) return;
    if (_accountKey != pair.account) return;
    if (folder.identity != pair.folder.identity) {
      throw const FormatException(
        'Select the original device folder to retain this pair’s history.',
      );
    }
    final updated = FolderPair(
      id: pair.id,
      account: pair.account,
      name: pair.name,
      folder: folder,
      remote: pair.remote,
      mode: pair.mode,
      repeat: pair.repeat,
      lastRun: pair.lastRun,
      wifiOnly: pair.wifiOnly,
      chargingOnly: pair.chargingOnly,
      rules: pair.rules,
      uploadConcurrency: pair.uploadConcurrency,
      background: pair.background,
      schedule: pair.schedule,
      revision: pair.revision,
    );
    await journal.save(updated);
    pairs[pairs.indexWhere((value) => value.id == pair.id)] = updated;
    error = null;
    _notify();
  }

  Future<void> toggleRepeat(FolderPair pair, bool value) async {
    final old = pair.repeat;
    pair.repeat = android && value;
    try {
      await journal.save(pair);
    } catch (_) {
      pair.repeat = old;
      rethrow;
    }
    _notify();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _albumTimer?.cancel();
      _albumTimer = null;
      if (!_backgroundRequested) _stop = true;
    } else {
      unawaited(refreshResults());
      if (ios) {
        _albumTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
          unawaited(checkAutomaticAlbums());
        });
        unawaited(checkAutomaticAlbums(force: true));
      }
    }
  }

  Future<void> checkAutomaticAlbums({bool force = false}) =>
      _automaticTask ??= _checkAutomaticAlbums(
        force: force,
      ).whenComplete(() => _automaticTask = null);

  Future<void> _checkAutomaticAlbums({required bool force}) async {
    if (!ios ||
        _disposed ||
        !_foreground ||
        _running != null ||
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
            pair.schedule == null ||
            pair.mode != SyncMode.backup) {
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
        if (!force &&
            (slot == null ||
                (state['revision'] == pair.revision &&
                    pair.schedule!.handled(slot, state['slot'] as String?)))) {
          continue;
        }
        await run(pair);
        if (_disposed || generation != _sessionGeneration) break;
        if (error == null &&
            !_stop &&
            results[pair.id]?['status'] == 'success' &&
            slot != null) {
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
        chargingOnly: pair.chargingOnly,
      );
    } else {
      await scheduler.cancel(pair.id);
    }
  }

  Future<void> pause() async {
    _stop = true;
    await _running;
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
    try {
      for (final pair in List.of(pairs)) {
        var state = await journal.state(pair.id);
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
        results[pair.id] = state;
        pair.lastRun = (await journal.pair(pair.id))?.lastRun;
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
    await pause();
    await _automaticTask;
    for (final pair
        in owner == null ? <FolderPair>[] : await journal.pairs(owner)) {
      await journal.writeState(pair.id, {'cancel': true});
      await scheduler.cancel(pair.id);
    }
    pairs = [];
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
    _backgroundRequested = !headless && android && pair.background;
    activeId = pair.id;
    statusPairId = pair.id;
    error = null;
    transferred = conflicts = 0;
    _notify();
    String? backgroundReason;
    var locked = false;
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
      if (_backgroundRequested) {
        await backgroundService.start((reason) {
          backgroundReason = reason;
          _stop = true;
        });
        _backgroundActive = true;
      }
      await _sync(session, pair);
    }();
    _running = task;
    try {
      await task;
      pair.lastRun = DateTime.now();
      await journal.completed(pair.id, pair.lastRun!);
      phase = 'Up to date · no files deleted';
    } on SyncStopped {
      phase = 'Paused · completed transfers are saved';
      error = backgroundReason;
    } on Object catch (e) {
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
            'Access to the selected folder was denied. Use Reconnect device folder '
                'to select the same folder again.',
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
            'Allow ncloud notifications in device Settings to use background uploads, '
                'or turn off Continue in background.',
          'background_start' =>
            'Android could not start the upload service. Open ncloud and retry, '
                'or turn off Continue in background.',
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
              'transferred': transferred,
              'finished': DateTime.now().toUtc().toIso8601String(),
            });
            results[pair.id] = await journal.state(pair.id);
          } finally {
            await runLock.release(pair.account);
          }
        }
      } finally {
        activeId = null;
        _running = null;
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
    final album = pair.folder.kind == DeviceSourceKind.photoAlbum;
    if (album && pair.mode != SyncMode.backup) {
      throw const FormatException(
        'Photos albums are read-only upload sources.',
      );
    }
    checkSyncPath(pair.cloudRoot);
    _validateRules(pair.rules, pair.uploadConcurrency);
    phase = 'Checking Wi-Fi and charging conditions';
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
    if (pair.includesSourceFolder) {
      final children = await client.listFiles(session, pair.remote);
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
      for (final item in await client.listFiles(session, [
        ...pair.cloudRoot,
        ...path,
      ])) {
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
    if (pair.mode != SyncMode.download) {
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
          await client.upload(
            session,
            [...pair.cloudRoot, ...target],
            staged.openRead(),
            stagedSize,
          );
          final confirmed =
              (await client.listFiles(session, [
                    ...pair.cloudRoot,
                    ...target.take(target.length - 1),
                  ]))
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
    if (pair.mode != SyncMode.backup) {
      for (final (path, file) in remote.values.toList()) {
        _check(pair);
        final receipt = await journal.receipt(pair.id, 'remote', path);
        final version = _remoteVersion(file);
        if (receipt != null && receipt['version'] == version) {
          final target = local[_key(_target(receipt))];
          if (target != null &&
              target.$2.version == receipt['target_version']) {
            continue;
          }
        }
        var target = path;
        if (local.containsKey(_key(target))) target = _conflict(path, 'cloud');
        await _conditions(pair);
        phase = 'Downloading ${file.name}';
        _notify();
        final staged = await access.stage();
        try {
          final response = await client.downloadVersion(session, file);
          final sink = staged.openWrite();
          try {
            await sink.addStream(
              response.stream.timeout(const Duration(minutes: 2)),
            );
            await sink.flush();
          } finally {
            await sink.close();
          }
          if (await staged.length() != file.size) {
            throw const FormatException(
              'Download was incomplete. Existing files are unchanged.',
            );
          }
          _check(pair);
          final saved = await access.import(pair.folder.token, target, staged);
          if (saved.name != target.last || saved.size != file.size) {
            throw const FormatException(
              'The folder provider did not confirm the saved file.',
            );
          }
          await journal.confirm(pair.id, target, saved.version, path, version);
          local[_key(target)] = (target, saved);
          transferred++;
          await journal.writeState(pair.id, {
            'transferred': transferred,
            'phase': phase,
          });
        } finally {
          await access.discard(staged);
        }
      }
    }
    _check(pair);
  }

  Future<void> _conditions(FolderPair pair) async {
    _check(pair);
    if (!pair.wifiOnly && !pair.chargingOnly) return;
    final conditions = await access.conditions();
    if (pair.wifiOnly && !conditions.wifi) {
      throw const FormatException(
        'Waiting for Wi-Fi. Connect and tap Sync now.',
      );
    }
    if (pair.chargingOnly && !conditions.charging) {
      throw const FormatException(
        'Waiting for charging. Connect power and tap Sync now.',
      );
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
      final children = await client.listFiles(session, parent);
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
    _albumTimer?.cancel();
    unawaited(
      (_running ?? Future<void>.value()).then((_) async {
        await _loading;
        await _automaticTask;
        await journal.close();
      }, onError: (Object _, StackTrace _) => journal.close()),
    );
    super.dispose();
  }
}
