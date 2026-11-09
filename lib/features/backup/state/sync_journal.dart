import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../engine/failure_policy.dart';
import '../model/folder_pair.dart';

export '../model/folder_pair.dart';

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
        version: 3,
        onConfigure: (db) async {
          await db.rawQuery('PRAGMA busy_timeout=5000');
          await db.rawQuery('PRAGMA journal_mode=WAL');
        },
        onUpgrade: (db, oldVersion, _) async {
          if (oldVersion < 2) await _createScheduleTables(db);
          if (oldVersion < 3) await _addLedger(db);
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
          await _addLedger(db);
        },
      ),
    );
  }

  /// Adds to the receipts and creates the failure list. Only ever adds: receipts
  /// are what stops a library being uploaded twice, so they are never dropped.
  static Future<void> _addLedger(Database db) async {
    await db.execute('ALTER TABLE receipts ADD COLUMN fingerprint TEXT');
    await db.execute('ALTER TABLE receipts ADD COLUMN size INTEGER');
    // Finding a file by its fingerprint must stay quick for a huge library.
    await db.execute(
      'CREATE INDEX receipts_fingerprint ON receipts(pair, fingerprint)',
    );
    await db.execute(
      'CREATE TABLE failures (pair TEXT NOT NULL, path TEXT NOT NULL, '
      'version TEXT NOT NULL, code TEXT, message TEXT NOT NULL, '
      'attempts INTEGER NOT NULL, at INTEGER NOT NULL, PRIMARY KEY(pair,path))',
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

  Future<void> save(
    FolderPair pair, {
    FolderPair? replacing,
  }) async => (await db).transaction((txn) async {
    await txn.insert('pairs', {
      'id': pair.id,
      'account': pair.account,
      'payload': jsonEncode(pair.toJson()),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
    if (replacing != null && replacing.id != pair.id) {
      await txn.delete('receipts', where: 'pair=?', whereArgs: [replacing.id]);
      await txn.delete('failures', where: 'pair=?', whereArgs: [replacing.id]);
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

  /// Records that [local] at [localVersion] was uploaded to [remote], which the
  /// server holds at [remoteVersion]. Later runs skip the file while both are
  /// unchanged.
  Future<void> confirm(
    String pair,
    List<String> local,
    String localVersion,
    List<String> remote,
    String remoteVersion, {
    String? fingerprint,
    int? size,
  }) async => (await db).insert(
    'receipts',
    _receiptRow(
      pair,
      local,
      localVersion,
      remote,
      remoteVersion,
      fingerprint,
      size,
    ),
    conflictAlgorithm: ConflictAlgorithm.replace,
  );

  static Map<String, Object?> _receiptRow(
    String pair,
    List<String> local,
    String localVersion,
    List<String> remote,
    String remoteVersion,
    String? fingerprint,
    int? size,
  ) => {
    'pair': pair,
    'side': 'local',
    'path': jsonEncode(local),
    'version': localVersion,
    'target': jsonEncode(remote),
    'target_version': remoteVersion,
    'fingerprint': fingerprint,
    'size': size,
  };

  /// Records many confirmed uploads in one transaction. A crash between uploads
  /// and this call loses at most the batch, and the next run recognises those
  /// files on the server instead of uploading them again.
  Future<void> confirmAll(String pair, List<Receipt> receipts) async {
    if (receipts.isEmpty) return;
    await (await db).transaction((txn) async {
      final batch = txn.batch();
      for (final r in receipts) {
        batch.insert(
          'receipts',
          _receiptRow(
            pair,
            r.path,
            r.version,
            r.target,
            r.targetVersion,
            r.fingerprint,
            r.size,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }
      await batch.commit(noResult: true);
    });
  }

  /// The receipts for [paths], looked up in groups so a library of a hundred
  /// thousand files costs a few hundred queries, not a hundred thousand. The
  /// result is keyed by the path as JSON.
  Future<Map<String, Receipt>> receiptsFor(
    String pair,
    Iterable<List<String>> paths,
  ) async {
    final database = await db;
    final wanted = [for (final path in paths) jsonEncode(path)];
    final found = <String, Receipt>{};
    const group = 400;
    for (var start = 0; start < wanted.length; start += group) {
      final keys = wanted.skip(start).take(group).toList();
      final rows = await database.query(
        'receipts',
        where:
            "pair=? AND side='local' AND path IN (${List.filled(keys.length, '?').join(',')})",
        whereArgs: [pair, ...keys],
      );
      for (final row in rows) {
        found[row['path'] as String] = Receipt.fromRow(row);
      }
    }
    return found;
  }

  /// Every receipt of [pair] whose file has this [fingerprint]: the same
  /// content wherever it was, or has since been moved to.
  Future<List<Receipt>> receiptsWithFingerprint(
    String pair,
    String fingerprint,
  ) async => [
    for (final row in await (await db).query(
      'receipts',
      where: "pair=? AND side='local' AND fingerprint=?",
      whereArgs: [pair, fingerprint],
    ))
      Receipt.fromRow(row),
  ];

  /// Replaces the receipt for a file that moved with one for its new place, in
  /// one step so a crash never leaves it with neither.
  Future<void> moveReceipt(String pair, List<String> from, Receipt to) async =>
      (await db).transaction((txn) async {
        await txn.delete(
          'receipts',
          where: "pair=? AND side='local' AND path=?",
          whereArgs: [pair, jsonEncode(from)],
        );
        await txn.insert(
          'receipts',
          _receiptRow(
            pair,
            to.path,
            to.version,
            to.target,
            to.targetVersion,
            to.fingerprint,
            to.size,
          ),
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      });

  /// Forgets what was uploaded for [pair], so the next run checks every file
  /// again. Files already on the server are recognised by their fingerprint.
  Future<void> resetReceipts(String pair) async =>
      (await db).transaction((txn) async {
        await txn.delete('receipts', where: 'pair=?', whereArgs: [pair]);
        await txn.delete('failures', where: 'pair=?', whereArgs: [pair]);
      });

  /// Notes that [failure] stopped a file from being backed up. [version] is the
  /// file's version then, so a changed file gets a fresh start.
  Future<void> recordFailure(
    String pair,
    FileFailure failure,
    String version,
  ) async {
    final database = await db;
    final key = jsonEncode(failure.path);
    final before = await database.query(
      'failures',
      columns: ['attempts', 'version'],
      where: 'pair=? AND path=?',
      whereArgs: [pair, key],
    );
    final attempts = before.isNotEmpty && before.single['version'] == version
        ? (before.single['attempts'] as int) + 1
        : 1;
    await database.insert('failures', {
      'pair': pair,
      'path': key,
      'version': version,
      'code': failure.code,
      'message': failure.message,
      'attempts': attempts,
      'at': DateTime.now().millisecondsSinceEpoch,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> clearFailure(String pair, List<String> path) async =>
      (await db).delete(
        'failures',
        where: 'pair=? AND path=?',
        whereArgs: [pair, jsonEncode(path)],
      );

  /// Files that failed and were not tried again since, newest first.
  Future<List<StoredFailure>> failures(String pair, {int limit = 200}) async =>
      [
        for (final row in await (await db).query(
          'failures',
          where: 'pair=?',
          whereArgs: [pair],
          orderBy: 'at DESC',
          limit: limit,
        ))
          StoredFailure.fromRow(row),
      ];

  Future<int> failureCount(String pair) async =>
      Sqflite.firstIntValue(
        await (await db).rawQuery(
          'SELECT COUNT(*) FROM failures WHERE pair=?',
          [pair],
        ),
      ) ??
      0;

  /// The recorded failures, keyed by path as JSON, for the files in [paths].
  Future<Map<String, StoredFailure>> failuresFor(
    String pair,
    Iterable<List<String>> paths,
  ) async {
    final database = await db;
    final wanted = [for (final path in paths) jsonEncode(path)];
    final found = <String, StoredFailure>{};
    const group = 400;
    for (var start = 0; start < wanted.length; start += group) {
      final keys = wanted.skip(start).take(group).toList();
      for (final row in await database.query(
        'failures',
        where:
            'pair=? AND path IN (${List.filled(keys.length, '?').join(',')})',
        whereArgs: [pair, ...keys],
      )) {
        found[row['path'] as String] = StoredFailure.fromRow(row);
      }
    }
    return found;
  }

  /// Gives every failed file a fresh start, such as when the user taps Retry.
  Future<void> resetFailures(String pair) async => (await db).update(
    'failures',
    {'attempts': 0},
    where: 'pair=?',
    whereArgs: [pair],
  );

  Future<void> forget(String id) async => (await db).transaction((txn) async {
    await txn.delete('run_state', where: 'pair=?', whereArgs: [id]);
    await txn.delete('receipts', where: 'pair=?', whereArgs: [id]);
    await txn.delete('failures', where: 'pair=?', whereArgs: [id]);
    await txn.delete('pairs', where: 'id=?', whereArgs: [id]);
  });

  /// Removes every folder pair, receipt and run state of [account], and its
  /// enabled flag, as when the account signs out.
  Future<void> clearAccount(String account) async => (await db).transaction((
    txn,
  ) async {
    for (final row in await txn.query(
      'pairs',
      columns: ['id'],
      where: 'account=?',
      whereArgs: [account],
    )) {
      final id = row['id'] as String;
      await txn.delete('run_state', where: 'pair=?', whereArgs: [id]);
      await txn.delete('receipts', where: 'pair=?', whereArgs: [id]);
      await txn.delete('failures', where: 'pair=?', whereArgs: [id]);
      await txn.delete('pairs', where: 'id=?', whereArgs: [id]);
    }
    await txn.delete('sync_sessions', where: 'account=?', whereArgs: [account]);
  });

  Future<void> close() async {
    await _opening;
    await _database?.close();
    _database = null;
  }
}

/// One confirmed upload: where the file was on the device, where it is on the
/// server, and the fingerprint that identifies its content.
class Receipt {
  const Receipt({
    required this.path,
    required this.version,
    required this.target,
    required this.targetVersion,
    this.fingerprint,
    this.size,
  });

  final List<String> path;
  final String version;
  final List<String> target;
  final String targetVersion;
  final String? fingerprint;
  final int? size;

  factory Receipt.fromRow(Map<String, Object?> row) => Receipt(
    path: (jsonDecode(row['path'] as String) as List).cast<String>(),
    version: row['version'] as String,
    target: (jsonDecode(row['target'] as String) as List).cast<String>(),
    targetVersion: row['target_version'] as String,
    fingerprint: row['fingerprint'] as String?,
    size: row['size'] as int?,
  );
}

/// A failure saved for a file, with how many runs it has now failed in.
class StoredFailure {
  const StoredFailure({
    required this.path,
    required this.version,
    required this.message,
    required this.attempts,
    required this.at,
    this.code,
  });

  final List<String> path;
  final String version;
  final String message;
  final String? code;
  final int attempts;
  final DateTime at;

  factory StoredFailure.fromRow(Map<String, Object?> row) => StoredFailure(
    path: (jsonDecode(row['path'] as String) as List).cast<String>(),
    version: row['version'] as String,
    message: row['message'] as String,
    code: row['code'] as String?,
    attempts: row['attempts'] as int,
    at: DateTime.fromMillisecondsSinceEpoch(row['at'] as int),
  );
}
