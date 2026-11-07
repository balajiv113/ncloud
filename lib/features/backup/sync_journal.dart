import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'folder_access.dart';
import '../../models.dart';
import 'sync_rules.dart';
import 'sync_schedule.dart';

String syncAccount(Account account) => '${account.server}|${account.userId}';

class FolderPair {
  FolderPair({
    required this.id,
    required this.account,
    required this.name,
    required this.folder,
    required this.remote,
    this.wifiOnly = true,
    this.lastRun,
    this.rules = const SyncRules.all(),
    this.uploadConcurrency = 1,
    this.schedule,
    this.revision = '',
    this.requiresSetup = false,
  });
  final String id;
  final String account;
  final String name;
  final DeviceFolder folder;
  final List<String> remote;
  final bool wifiOnly;
  DateTime? lastRun;
  final SyncRules rules;
  final int uploadConcurrency;
  final BackupSchedule? schedule;
  final String revision;
  final bool requiresSetup;

  List<String> get cloudRoot => [...remote, folder.name];

  Map<String, Object?> toJson() => {
    'id': id,
    'account': account,
    'name': name,
    'token': folder.token,
    'folderName': folder.name,
    'identity': folder.identity,
    'sourceKind': folder.kind.name,
    'remote': remote,
    'wifiOnly': wifiOnly,
    'lastRun': lastRun?.toIso8601String(),
    'rules': rules.toJson(),
    'uploadConcurrency': uploadConcurrency,
    'schedule': schedule?.toJson(),
    'revision': revision,
    if (requiresSetup) 'requiresSetup': true,
  };

  factory FolderPair.fromJson(Map<String, dynamic> value) {
    final requiresSetup =
        value['requiresSetup'] == true ||
        (value['mode'] != null && value['mode'] != 'backup');
    return FolderPair(
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
      wifiOnly: value['wifiOnly'] as bool,
      lastRun: DateTime.tryParse(value['lastRun'] as String? ?? ''),
      rules: SyncRules.fromJson(
        (value['rules'] as Map).cast<String, dynamic>(),
      ),
      uploadConcurrency: value['uploadConcurrency'] as int,
      schedule: requiresSetup || value['schedule'] == null
          ? null
          : BackupSchedule.fromJson(
              (value['schedule'] as Map).cast<String, dynamic>(),
            ),
      revision:
          value['schedule'] is Map &&
              (value['schedule'] as Map)['kind'] != null &&
              (value['schedule'] as Map)['kind'] != 'daily'
          ? 'daily-${value['revision']}'
          : value['revision'] as String? ?? '',
      requiresSetup: requiresSetup,
    );
  }
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
        // Each engine must close only its own connection when a worker ends.
        singleInstance: false,
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
      whereArgs: [pair, side, jsonEncode(path)],
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
        'path': jsonEncode(path),
        'version': version,
        'target': jsonEncode(target),
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
