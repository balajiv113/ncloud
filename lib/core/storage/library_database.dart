import 'dart:convert';
import 'dart:io';

import 'package:sqflite/sqflite.dart';

import '../../file_store.dart';
import '../../models.dart';

/// Disposable, account-scoped metadata. Originals and their manifest never
/// enter this database. No timer or maintenance runs while the app is idle.
class LibraryDatabase {
  LibraryDatabase(
    String path, {
    DatabaseFactory? factory,
    required this.onError,
    this.prepareStorage,
    this.reclaimStorage,
  }) : path = File(path).absolute.path,
       _factory = factory ?? databaseFactory;

  static const schemaVersion = 5;
  final String path;
  final DatabaseFactory _factory;
  final void Function(String) onError;
  final Future<void> Function()? prepareStorage;
  final Future<bool> Function(int attempt)? reclaimStorage;
  Database? _database;
  Future<Database>? _opening;
  final Map<String, int> _accessed = {};

  static String accountFor(String key) {
    final parts = key.split('|');
    return parts.length >= 3 ? '${parts[1]}|${parts[2]}' : key;
  }

  static String identity(CloudFile file) =>
      file.id?.isNotEmpty == true ? 'id:${file.id}' : 'path:${file.key}';

  Future<Database> _open() =>
      _opening ??= _openDatabase().whenComplete(() => _opening = null);

  Future<Database> _openDatabase() async {
    if (_database case final database?) return database;
    await Directory(File(path).parent.path).create(recursive: true);
    final creating = !await File(path).exists();
    return _database = await _factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: schemaVersion,
        singleInstance: false,
        onConfigure: (db) async {
          if (creating) await db.execute('PRAGMA auto_vacuum = INCREMENTAL');
          await db.execute('PRAGMA foreign_keys = ON');
          await db.rawQuery('PRAGMA journal_mode = WAL');
          await db.execute('PRAGMA synchronous = NORMAL');
          await db.rawQuery('PRAGMA wal_autocheckpoint = 256');
          await db.rawQuery('PRAGMA journal_size_limit = 1048576');
          await db.execute('PRAGMA cache_size = -2048');
        },
        onCreate: (db, version) async {
          await _createSchema(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          await db.execute('DROP TABLE IF EXISTS members');
          await db.execute('DROP TABLE IF EXISTS collections');
          await db.execute('DROP TABLE IF EXISTS files');
          await _createSchema(db);
        },
      ),
    );
  }

  static Future<void> _createSchema(Database db) async {
    await db.execute('''
      CREATE TABLE files (
        account TEXT NOT NULL, file_key TEXT NOT NULL, path_key TEXT NOT NULL,
        path TEXT NOT NULL, name TEXT NOT NULL, is_directory INTEGER NOT NULL,
        content_type TEXT NOT NULL, size INTEGER NOT NULL, modified TEXT,
        file_id TEXT, favorite INTEGER NOT NULL, color INTEGER, album_path TEXT,
        taken TEXT, capture_day INTEGER, etag TEXT,
        observed_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (account, file_key)
      ) WITHOUT ROWID
    ''');
    await db.execute('''
      CREATE TABLE collections (
        cache_key TEXT PRIMARY KEY, account TEXT NOT NULL, kind TEXT NOT NULL,
        payload TEXT NOT NULL, accessed INTEGER NOT NULL
      )
    ''');
    await db.execute('''
      CREATE TABLE members (
        collection_key TEXT NOT NULL REFERENCES collections(cache_key)
          ON DELETE CASCADE,
        position INTEGER NOT NULL, file_key TEXT, path_key TEXT NOT NULL,
        PRIMARY KEY (collection_key, position)
      ) WITHOUT ROWID
    ''');
    await db.execute('CREATE INDEX files_path ON files(account, path_key)');
    await db.execute(
      'CREATE INDEX files_timeline ON files(account, capture_day, taken)',
    );
    await db.execute(
      'CREATE INDEX files_type ON files(account, content_type, favorite)',
    );
    await db.execute('CREATE INDEX members_file ON members(file_key)');
    await db.execute('CREATE INDEX members_path ON members(path_key)');
    await db.execute(
      'CREATE INDEX members_lookup ON members(collection_key, path_key)',
    );
    await db.execute(
      'CREATE INDEX collections_access ON collections(accessed)',
    );
    await db.execute(
      'CREATE INDEX collections_account ON collections(account, kind)',
    );
  }

  bool _corrupt(Object error) {
    final message = error.toString().toLowerCase();
    return message.contains('database disk image is malformed') ||
        message.contains('file is not a database') ||
        message.contains('database corruption') ||
        message.contains('sqlite_corrupt') ||
        message.contains('sqlite_notadb');
  }

  Future<T> _run<T>(
    Future<T> Function(Database) operation, {
    bool reserveSpace = true,
  }) async {
    if (reserveSpace) await prepareStorage?.call();
    var storageRetries = 0;
    var busyRetried = false;
    var rebuilt = false;
    while (true) {
      try {
        return await operation(await _open());
      } catch (error) {
        final code = error is DatabaseException
            ? (error.getResultCode() ?? 0) & 0xff
            : null;
        final full =
            code == 13 ||
            (error is FileSystemException && error.osError?.errorCode == 28);
        if (full &&
            storageRetries < 3 &&
            await reclaimStorage?.call(storageRetries++) == true) {
          continue;
        }
        if (!busyRetried && (code == 5 || code == 6)) {
          // Transactions have rolled back before retrying; never spin while idle.
          busyRetried = true;
          await Future<void>.delayed(const Duration(milliseconds: 75));
          continue;
        }
        if (rebuilt || !_corrupt(error)) rethrow;
        rebuilt = true;
        onError(
          'The local library catalogue was damaged and has been rebuilt. '
          'Saved originals are unaffected; reconnect to reload library metadata.',
        );
        await close();
        await _factory.deleteDatabase(path);
      }
    }
  }

  Map<String, Object?> _row(String account, CloudFile file) {
    final value = file.toJson();
    return {
      'account': account,
      'file_key': identity(file),
      'path_key': file.key,
      'path': jsonEncode(file.path),
      'name': file.name,
      'is_directory': file.isDirectory ? 1 : 0,
      'content_type': file.contentType,
      'size': file.size,
      'modified': value['modified'],
      'file_id': file.id,
      'favorite': file.favorite ? 1 : 0,
      'color': file.demoColor,
      'album_path': file.albumReference == null
          ? null
          : jsonEncode(file.albumReference),
      'taken': value['taken'],
      'capture_day': file.captureDay,
      'etag': file.etag,
    };
  }

  CloudFile _file(Map<String, Object?> row) => CloudFile.fromJson({
    'path': jsonDecode(row['path'] as String),
    'name': row['name'],
    'dir': row['is_directory'] == 1,
    'type': row['content_type'],
    'size': row['size'],
    'modified': row['modified'],
    'id': row['file_id'],
    'favorite': row['favorite'] == 1,
    'color': row['color'],
    'albumReference': row['album_path'] == null
        ? null
        : jsonDecode(row['album_path'] as String),
    'taken': row['taken'],
    'captureDay': row['capture_day'],
    'etag': row['etag'],
  });

  Future<({Map<String, String> keys, Set<String> upgrades})> _identities(
    Transaction txn,
    String account,
    Iterable<CloudFile> files,
  ) async {
    final rows = files.toList();
    final paths = <String, String>{};
    final ambiguous = <String>{};
    final upgrades = <String>{};
    for (final file in rows) {
      final id = file.id;
      if (id == null || id.isEmpty) continue;
      final old = paths[id];
      if (old != null && old != file.key) ambiguous.add(id);
      paths[id] = file.key;
    }
    for (var start = 0; start < rows.length; start += 300) {
      final chunk = rows.skip(start).take(300).toList();
      final ids = chunk.map((file) => file.id).whereType<String>().toSet();
      final known = await txn.query(
        'files',
        columns: ['file_id', 'path_key'],
        where:
            "account=? AND file_key LIKE 'path:%' AND ("
            '${ids.isEmpty ? '' : 'file_id IN (${List.filled(ids.length, '?').join(',')}) OR '}'
            'path_key IN (${List.filled(chunk.length, '?').join(',')}))',
        whereArgs: [account, ...ids, ...chunk.map((file) => file.key)],
      );
      for (final row in known) {
        final id = row['file_id'] as String?;
        if (id == null) {
          upgrades.add(row['path_key'] as String);
        } else {
          ambiguous.add(id);
        }
      }
    }
    return (
      keys: {
        for (final file in rows)
          file.key: ambiguous.contains(file.id)
              ? 'path:${file.key}'
              : identity(file),
      },
      upgrades: upgrades,
    );
  }

  void _upsertFile(
    Batch batch,
    String account,
    CloudFile file,
    String fileKey, {
    bool promote = false,
    required int observedAt,
  }) {
    final row = _row(account, file);
    row['file_key'] = fileKey;
    row['observed_at'] = observedAt;
    if (file.id?.isNotEmpty == true) {
      if (fileKey.startsWith('path:')) {
        // Some DAV servers (and imported fixtures) reuse an ID for distinct
        // paths. Such an ambiguous ID cannot be a stable primary key.
        batch.rawUpdate(
          'UPDATE members SET file_key=? WHERE file_key=? AND path_key=? '
          'AND collection_key IN '
          '(SELECT cache_key FROM collections WHERE account=?)',
          [fileKey, identity(file), file.key, account],
        );
        batch.delete(
          'files',
          where: 'account=? AND file_key=?',
          whereArgs: [account, identity(file)],
        );
      } else if (promote) {
        // Upgrade path-only records when the server finally supplies an ID.
        batch.rawUpdate(
          'UPDATE members SET file_key=? WHERE file_key=? '
          'AND collection_key IN '
          '(SELECT cache_key FROM collections WHERE account=?)',
          [fileKey, 'path:${file.key}', account],
        );
        batch.delete(
          'files',
          where: 'account=? AND file_key=? AND file_id IS NULL',
          whereArgs: [account, 'path:${file.key}'],
        );
      }
    }
    final columns = row.keys.toList();
    final changed = columns.skip(2).toList();
    // UPDATE + INSERT OR IGNORE also works with Android's older SQLite
    // versions, while unchanged rows cause no page writes.
    batch.rawUpdate(
      'UPDATE files SET ${changed.map((c) => '$c=?').join(',')} '
      'WHERE account=? AND file_key=? AND '
      '(${changed.map((c) => '$c IS NOT ?').join(' OR ')})',
      [
        ...changed.map((column) => row[column]),
        account,
        fileKey,
        ...changed.map((column) => row[column]),
      ],
    );
    batch.insert('files', row, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> _upsertFiles(
    Transaction txn,
    String account,
    List<CloudFile> files,
    ({Map<String, String> keys, Set<String> upgrades}) identities, {
    Map<String, DateTime>? observedAt,
  }) async {
    final now = DateTime.now().microsecondsSinceEpoch;
    for (var start = 0; start < files.length; start += 256) {
      final batch = txn.batch();
      for (final file in files.skip(start).take(256)) {
        _upsertFile(
          batch,
          account,
          file,
          identities.keys[file.key]!,
          promote: identities.upgrades.contains(file.key),
          observedAt: observedAt == null
              ? now
              : observedAt[file.key]?.microsecondsSinceEpoch ?? 0,
        );
      }
      await batch.commit(noResult: true);
    }
  }

  Future<void> _collection(
    Transaction txn,
    String key,
    String kind,
    Map<String, dynamic> payload,
  ) async {
    final encoded = jsonEncode(payload);
    final now = DateTime.now().millisecondsSinceEpoch;
    await txn.rawUpdate(
      'UPDATE collections SET payload=?,kind=?,accessed=? WHERE cache_key=? '
      'AND (payload IS NOT ? OR kind IS NOT ?)',
      [encoded, kind, now, key, encoded, kind],
    );
    await txn.insert('collections', {
      'cache_key': key,
      'account': accountFor(key),
      'kind': kind,
      'payload': encoded,
      'accessed': now,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
    if (_accessed.length >= 4096) _accessed.clear();
    _accessed[key] = now;
  }

  Future<void> _members(
    Transaction txn,
    String key,
    List<({String path, String? identity})> next,
  ) async {
    final old = await txn.query(
      'members',
      where: 'collection_key=?',
      whereArgs: [key],
      orderBy: 'position',
    );
    var batch = txn.batch();
    for (var i = 0; i < next.length; i++) {
      if (i > 0 && i % 256 == 0) {
        await batch.commit(noResult: true);
        batch = txn.batch();
      }
      final item = next[i];
      if (i < old.length &&
          old[i]['position'] == i &&
          old[i]['path_key'] == item.path &&
          old[i]['file_key'] == item.identity) {
        continue;
      }
      batch.insert('members', {
        'collection_key': key,
        'position': i,
        'path_key': item.path,
        'file_key': item.identity,
      }, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    if (old.length > next.length) {
      batch.delete(
        'members',
        where: 'collection_key=? AND position>=?',
        whereArgs: [key, next.length],
      );
    }
    await batch.commit(noResult: true);
  }

  Future<void> _touch(Database db, String key) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    var last = _accessed[key];
    if (last == null) {
      final rows = await db.query(
        'collections',
        columns: ['accessed'],
        where: 'cache_key=?',
        whereArgs: [key],
      );
      last = rows.isEmpty ? now : rows.single['accessed'] as int;
      if (_accessed.length >= 4096) _accessed.clear();
      _accessed[key] = last;
    }
    if (now - last < const Duration(minutes: 5).inMilliseconds) return;
    if (_accessed.length >= 4096) _accessed.clear();
    _accessed[key] = now;
    await db.update(
      'collections',
      {'accessed': now},
      where: 'cache_key=?',
      whereArgs: [key],
    );
  }

  Future<void> writeListing(String key, List<CloudFile> files) => _run(
    (db) => db.transaction((txn) async {
      final bounded = files.take(FileStore.maxFiles).toList();
      await _collection(txn, key, 'listing', {});
      final identities = await _identities(txn, accountFor(key), bounded);
      await _upsertFiles(txn, accountFor(key), bounded, identities);
      await _members(txn, key, [
        for (final file in bounded)
          (path: file.key, identity: identities.keys[file.key]),
      ]);
    }),
  );

  Future<List<CloudFile>?> readListing(String key) => _run((db) async {
    final collection = await db.query(
      'collections',
      columns: ['kind'],
      where: 'cache_key=? AND kind IN (?,?)',
      whereArgs: [key, 'listing', 'view'],
    );
    if (collection.isEmpty) return null;
    final link = collection.single['kind'] == 'view'
        ? 'f.path_key=m.path_key'
        : 'f.file_key=m.file_key';
    final rows = await db.rawQuery(
      'SELECT f.* FROM members m LEFT JOIN files f '
      'ON f.account=? AND $link '
      'WHERE m.collection_key=? ORDER BY m.position LIMIT ?',
      [accountFor(key), key, FileStore.maxFiles],
    );
    if (rows.any((row) => row['file_key'] == null)) return null;
    await _touch(db, key);
    return rows.map(_file).toList();
  });

  Future<bool> containsCollection(String key) => _run((db) async {
    final rows = await db.query(
      'collections',
      columns: ['cache_key'],
      where: 'cache_key=?',
      whereArgs: [key],
      limit: 1,
    );
    return rows.isNotEmpty;
  });

  Future<List<CloudFile>> readFilesByIds(
    String accountKey,
    Iterable<String> ids,
  ) => _run((db) async {
    final requested = ids.take(FileStore.maxFiles).toSet().toList();
    final files = <CloudFile>[];
    for (var start = 0; start < requested.length; start += 400) {
      final chunk = requested.skip(start).take(400).toList();
      final rows = await db.query(
        'files',
        where:
            'account=? AND file_id IN '
            '(${List.filled(chunk.length, '?').join(',')})',
        whereArgs: [accountFor(accountKey), ...chunk],
        limit: FileStore.maxFiles - files.length,
      );
      files.addAll(rows.map(_file));
    }
    return files;
  });

  /// Raw persisted day rows, not a freshness or completeness guarantee. The
  /// caller must compare the server count and its listing invalidation state.
  Future<List<CloudFile>> readDayFiles(
    String accountKey,
    List<int> days, {
    DateTime? freshSince,
  }) => _run((db) async {
    final requested = days.take(FileStore.maxFiles).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    final files = <CloudFile>[];
    for (
      var start = 0;
      start < requested.length && files.length < FileStore.maxFiles;
      start += 400
    ) {
      final chunk = requested.skip(start).take(400).toList();
      final rows = await db.query(
        'files',
        where:
            'account=? AND is_directory=0 AND album_path IS NULL '
            'AND capture_day IN '
            '(${List.filled(chunk.length, '?').join(',')})'
            '${freshSince == null ? '' : ' AND observed_at>=?'}',
        whereArgs: [
          accountFor(accountKey),
          ...chunk,
          if (freshSince != null) freshSince.microsecondsSinceEpoch,
        ],
        orderBy: 'capture_day DESC, taken DESC, modified DESC, file_key ASC',
        limit: FileStore.maxFiles - files.length,
      );
      files.addAll(rows.map(_file));
    }
    return files;
  });

  Future<({List<CloudFile> files, String? etag, DateTime updated})?>
  readFolderSnapshot(String accountKey, List<String> folder) =>
      _run((db) async {
        final account = accountFor(accountKey);
        final key = _folderKey('library-v1|$account', pathKey(folder));
        final rows = await db.query(
          'collections',
          columns: ['payload'],
          where: 'cache_key=? AND kind=?',
          whereArgs: [key, 'folder'],
        );
        if (rows.isEmpty) return null;
        final payload = jsonDecode(rows.single['payload'] as String) as Map;
        final members = await db.rawQuery(
          'SELECT f.* FROM members m LEFT JOIN files f '
          'ON f.account=? AND f.path_key=m.path_key '
          'WHERE m.collection_key=? ORDER BY m.position LIMIT ?',
          [account, key, FileStore.maxFiles],
        );
        if (members.any((row) => row['file_key'] == null)) return null;
        final files = members.map(_file).toList();
        if (!FileStore.validChildren(folder, files)) return null;
        await _touch(db, key);
        return (
          files: files,
          etag: payload['etag'] as String?,
          updated: DateTime.parse(payload['updated'] as String),
        );
      });

  Future<void> invalidateListings(String accountKey) => _run(
    (db) => db.transaction((txn) async {
      final account = accountFor(accountKey);
      final cached = await txn.query(
        'collections',
        columns: ['cache_key', 'kind', 'payload'],
        where: 'account=? AND kind IN (?,?)',
        whereArgs: [account, 'view', 'folder'],
      );
      for (final collection in cached) {
        final payload = (jsonDecode(collection['payload'] as String) as Map)
            .cast<String, dynamic>();
        payload['updated'] = DateTime.fromMillisecondsSinceEpoch(
          0,
        ).toIso8601String();
        if (collection['kind'] == 'view') {
          payload['staleDays'] = {
            ...((payload['staleDays'] as List?) ?? const []),
            ...((payload['loaded'] as List?) ?? const []),
          }.toList();
        }
        await txn.update(
          'collections',
          {'payload': jsonEncode(payload)},
          where: 'cache_key=?',
          whereArgs: [collection['cache_key']],
        );
      }
      final libraries = await txn.query(
        'collections',
        columns: ['cache_key'],
        where: 'account=? AND kind=?',
        whereArgs: [account, 'library'],
      );
      for (final library in libraries) {
        await txn.update(
          'collections',
          {
            'payload': jsonEncode({
              'staleBefore': DateTime.now().toIso8601String(),
            }),
          },
          where: 'cache_key=?',
          whereArgs: [library['cache_key']],
        );
      }
      _accessed.clear();
    }),
  );

  Future<void> writeDocument(String key, Map<String, dynamic> value) async {
    await _run(
      (db) => db.transaction((txn) async {
        final payload = Map<String, dynamic>.of(value);
        final keys = payload.remove('keys');
        await _collection(
          txn,
          key,
          keys is List ? 'view' : 'document',
          payload,
        );
        if (keys is List) {
          await _members(txn, key, [
            for (final path in keys.take(FileStore.maxFiles))
              (path: path as String, identity: null),
          ]);
        }
      }),
    );
  }

  Future<Map<String, dynamic>?> readDocument(String key) => _run((db) async {
    final rows = await db.query(
      'collections',
      where: 'cache_key=?',
      whereArgs: [key],
    );
    if (rows.isEmpty) return null;
    final collection = rows.single;
    final payload = (jsonDecode(collection['payload'] as String) as Map)
        .cast<String, dynamic>();
    final kind = collection['kind'];
    if (kind == 'library') {
      final files = await db.rawQuery(
        'SELECT f.* FROM members m JOIN files f '
        'ON f.account=? AND f.file_key=m.file_key '
        'WHERE m.collection_key=? ORDER BY m.position DESC LIMIT ?',
        [accountFor(key), key, FileStore.maxFiles],
      );
      final folders = await db.query(
        'collections',
        where: 'account=? AND kind=?',
        whereArgs: [accountFor(key), 'folder'],
        orderBy: 'accessed DESC',
        limit: FileStore.maxFolders,
      );
      final folderValues = <String, dynamic>{};
      var remaining = FileStore.maxFolderMembers;
      for (final folder in folders) {
        if (remaining <= 0) break;
        final members = await db.query(
          'members',
          columns: ['path_key'],
          where: 'collection_key=?',
          whereArgs: [folder['cache_key']],
          orderBy: 'position',
          limit: remaining + 1,
        );
        if (members.length > remaining) continue;
        remaining -= members.length;
        final info = (jsonDecode(folder['payload'] as String) as Map)
            .cast<String, dynamic>();
        final folderPath = info.remove('path') as String;
        folderValues[folderPath] = {
          ...info,
          'children': [for (final row in members) row['path_key']],
        };
      }
      payload['files'] = [
        for (final row in files.reversed) _file(row).toJson(),
      ];
      payload['folders'] = folderValues;
    } else if (kind == 'view') {
      final members = await db.query(
        'members',
        columns: ['path_key'],
        where: 'collection_key=?',
        whereArgs: [key],
        orderBy: 'position',
        limit: FileStore.maxFiles,
      );
      payload['keys'] = [for (final row in members) row['path_key']];
    } else if (kind != 'document') {
      return null;
    }
    await _touch(db, key);
    return payload;
  });

  String _folderKey(String key, String path) => '$key|folder|$path';

  Future<void> writeLibrary(String key, FileStoreChanges changes) => _run(
    (db) => db.transaction((txn) async {
      final account = accountFor(key);
      if (changes.replace) {
        await txn.delete(
          'collections',
          where: 'account=? AND kind IN (?,?)',
          whereArgs: [account, 'library', 'folder'],
        );
      }
      await _collection(txn, key, 'library', {
        'staleBefore': changes.staleBefore.toIso8601String(),
      });
      final identities = await _identities(
        txn,
        account,
        changes.files.values.whereType<CloudFile>(),
      );
      await _upsertFiles(
        txn,
        account,
        changes.files.values.whereType<CloudFile>().toList(),
        identities,
        observedAt: changes.observedAt,
      );
      final existing = <String, Map<String, Object?>>{};
      final paths = changes.files.keys.toList();
      if (!changes.replace) {
        for (var start = 0; start < paths.length; start += 300) {
          final chunk = paths.skip(start).take(300).toList();
          final old = await txn.query(
            'members',
            columns: ['path_key', 'file_key', 'position'],
            where:
                'collection_key=? AND path_key IN '
                '(${List.filled(chunk.length, '?').join(',')})',
            whereArgs: [key, ...chunk],
          );
          for (final member in old) {
            existing[member['path_key'] as String] = member;
          }
        }
      }
      final maximum = await txn.rawQuery(
        'SELECT MAX(position) AS position FROM members WHERE collection_key=?',
        [key],
      );
      var position = maximum.single['position'] as int? ?? -1;
      var membership = txn.batch();
      var count = 0;
      for (final entry in changes.files.entries) {
        if (++count % 256 == 0) {
          await membership.commit(noResult: true);
          membership = txn.batch();
        }
        final oldMember = existing[entry.key];
        final file = entry.value;
        if (file == null) {
          membership.delete(
            'files',
            where: 'account=? AND path_key=?',
            whereArgs: [account, entry.key],
          );
        }
        if (oldMember != null && file == null) {
          membership.delete(
            'members',
            where: 'collection_key=? AND position=?',
            whereArgs: [key, oldMember['position']],
          );
        } else if (file != null &&
            (oldMember == null ||
                oldMember['file_key'] != identities.keys[file.key])) {
          membership.insert('members', {
            'collection_key': key,
            'position': oldMember?['position'] ?? ++position,
            'path_key': entry.key,
            'file_key': identities.keys[file.key],
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await membership.commit(noResult: true);
      for (final entry in changes.folders.entries) {
        final folderKey = _folderKey(key, entry.key);
        final folder = entry.value;
        if (folder == null) {
          await txn.delete(
            'collections',
            where: 'cache_key=?',
            whereArgs: [folderKey],
          );
          continue;
        }
        await _collection(txn, folderKey, 'folder', {
          'path': entry.key,
          'updated': folder['updated'],
          'etag': folder['etag'],
        });
        await _members(txn, folderKey, [
          for (final child in folder['children'] as List<String>)
            (path: child, identity: null),
        ]);
      }
      // An incremental store eviction removes its membership, not another
      // listing's copy of the same stable file.
      if (changes.replace || changes.files.values.any((file) => file == null)) {
        await _deleteOrphans(txn);
      }
    }),
  );

  Future<void> _deleteOrphans(DatabaseExecutor db) => db.execute('''
    DELETE FROM files WHERE NOT EXISTS (
      SELECT 1 FROM members m INDEXED BY members_file JOIN collections c
        ON c.cache_key=m.collection_key
      WHERE m.file_key=files.file_key AND c.account=files.account
    ) AND NOT EXISTS (
      SELECT 1 FROM members m INDEXED BY members_path JOIN collections c
        ON c.cache_key=m.collection_key
      WHERE m.path_key=files.path_key AND c.account=files.account
    )
  ''');

  Future<void> clearDocuments() => _run(
    (db) => db.transaction((txn) async {
      await txn.delete('collections', where: 'kind<>?', whereArgs: ['listing']);
      await _deleteOrphans(txn);
      _accessed.clear();
    }),
  );

  Future<void> clear() => _run(
    (db) => db.transaction((txn) async {
      await txn.delete('collections');
      await txn.delete('files');
      _accessed.clear();
    }),
  );

  Future<int> allocatedBytes() async {
    var bytes = 0;
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final file = File('$path$suffix');
      if (await file.exists()) bytes += await file.length();
    }
    return bytes;
  }

  Future<void> checkpoint() => _run(
    (db) async => db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)'),
    reserveSpace: false,
  );

  /// Called only under budget pressure, never on a schedule. Incremental
  /// vacuum reclaims free pages without rewriting the entire catalogue.
  Future<void> trimToBytes(int target) async {
    if (await allocatedBytes() <= target) return;
    await _run((db) async {
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      while (await allocatedBytes() > target) {
        final oldest = await db.query(
          'collections',
          columns: ['cache_key'],
          orderBy: 'accessed',
          limit: 32,
        );
        if (oldest.isEmpty) break;
        await db.transaction((txn) async {
          final batch = txn.batch();
          for (final row in oldest) {
            batch.delete(
              'collections',
              where: 'cache_key=?',
              whereArgs: [row['cache_key']],
            );
            _accessed.remove(row['cache_key']);
          }
          await batch.commit(noResult: true);
          await _deleteOrphans(txn);
        });
        await db.rawQuery('PRAGMA incremental_vacuum(4096)');
        await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      }
      await db.rawQuery('PRAGMA incremental_vacuum(4096)');
      await db.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
    });
    if (await allocatedBytes() > target) {
      // Even the empty schema cannot fit an unusually small configured budget.
      // Close first: never unlink a live SQLite database.
      await close();
      await _factory.deleteDatabase(path);
    }
  }

  Future<void> close() async {
    final pending = _opening;
    if (pending != null) {
      try {
        await pending;
      } catch (_) {
        // Opening failures must not prevent corruption recovery.
      }
    }
    final database = _database;
    _database = null;
    _accessed.clear();
    await database?.close();
  }
}
