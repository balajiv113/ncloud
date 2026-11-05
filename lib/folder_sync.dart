import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'models.dart';
import 'nextcloud_client.dart';

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

class DeviceFolder {
  const DeviceFolder(this.token, this.name, this.identity);
  final String token;
  final String name;
  final String identity;
}

class DeviceEntry {
  const DeviceEntry(this.name, this.directory, this.size, this.modified);
  final String name;
  final bool directory;
  final int size;
  final int modified;
  String get version => '$size|$modified';
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

class NativeFolderAccess implements FolderAccess {
  static const channel = MethodChannel('app.ncloud/folder_sync');

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

  Map<String, Object?> toJson() => {
    'id': id,
    'account': account,
    'name': name,
    'token': folder.token,
    'folderName': folder.name,
    'identity': folder.identity,
    'remote': remote,
    'mode': mode.name,
    'repeat': repeat,
    'wifiOnly': wifiOnly,
    'chargingOnly': chargingOnly,
    'lastRun': lastRun?.toIso8601String(),
  };

  factory FolderPair.fromJson(Map<String, dynamic> value) => FolderPair(
    id: value['id'] as String,
    account: value['account'] as String,
    name: value['name'] as String,
    folder: DeviceFolder(
      value['token'] as String,
      value['folderName'] as String,
      value['identity'] as String,
    ),
    remote: (value['remote'] as List).cast<String>(),
    mode: SyncMode.values.byName(value['mode'] as String),
    repeat: value['repeat'] as bool,
    wifiOnly: value['wifiOnly'] as bool? ?? true,
    chargingOnly: value['chargingOnly'] as bool? ?? false,
    lastRun: DateTime.tryParse(value['lastRun'] as String? ?? ''),
  );
}

class SyncJournal {
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
        version: 1,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE pairs (id TEXT PRIMARY KEY, account TEXT NOT NULL, '
            'payload TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE receipts (pair TEXT NOT NULL, side TEXT NOT NULL, '
            'path TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, '
            'target_version TEXT NOT NULL, PRIMARY KEY(pair,side,path))',
          );
        },
      ),
    );
  }

  Future<List<FolderPair>> pairs(String account) async => [
    for (final row in await (await db).query(
      'pairs',
      where: 'account=?',
      whereArgs: [account],
    ))
      FolderPair.fromJson(
        (jsonDecode(row['payload'] as String) as Map).cast<String, dynamic>(),
      ),
  ];

  Future<void> save(FolderPair pair) async => (await db).insert('pairs', {
    'id': pair.id,
    'account': pair.account,
    'payload': jsonEncode(pair.toJson()),
  }, conflictAlgorithm: ConflictAlgorithm.replace);

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
  }) : access = access ?? NativeFolderAccess(),
       journal = journal ?? SyncJournal(),
       android = android ?? Platform.isAndroid;

  final NextcloudClient client;
  final Account? Function() account;
  final FolderAccess access;
  final SyncJournal journal;
  final bool android;
  List<FolderPair> pairs = [];
  String? error;
  String? activeId;
  String phase = '';
  int transferred = 0;
  int conflicts = 0;
  bool _foreground = true;
  bool _stop = false;
  bool _disposed = false;
  Timer? _timer;
  Future<void>? _running;
  Future<void>? _loading;
  String? _owner;

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> load() =>
      _loading ??= _load().whenComplete(() => _loading = null);

  Future<void> _load() async {
    final session = account();
    if (session == null) return;
    if (_owner == syncAccount(session)) {
      _schedule();
      return;
    }
    if (_owner != null && _owner != syncAccount(session)) {
      pairs = [];
      _owner = null;
      _notify();
    }
    try {
      final saved = await journal.pairs(syncAccount(session));
      if (syncAccount(session) != _accountKey || _disposed) return;
      _owner = _accountKey;
      pairs = saved;
      error = null;
      _schedule();
    } on Object {
      error = 'Could not read sync pairs. Check device storage and retry.';
    }
    _notify();
  }

  String? get _accountKey => account() == null ? null : syncAccount(account()!);

  Future<void> add(
    String name,
    DeviceFolder folder,
    List<String> remote,
    SyncMode mode,
    bool repeat, {
    bool wifiOnly = true,
    bool chargingOnly = false,
  }) async {
    final owner = _accountKey;
    if (owner == null || owner != _owner) throw StateError('Reconnect first.');
    checkSyncPath(remote);
    bool overlaps(List<String> a, List<String> b) =>
        a.length <= b.length &&
        List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);
    if (pairs.any(
      (pair) =>
          pair.folder.identity == folder.identity ||
          overlaps(pair.remote, remote) ||
          overlaps(remote, pair.remote),
    )) {
      throw const FormatException(
        'Choose a different device folder and a non-overlapping cloud folder.',
      );
    }
    final pair = FolderPair(
      id: _id(),
      account: owner,
      name: name.trim().isEmpty ? folder.name : name.trim(),
      folder: folder,
      remote: List.of(remote),
      mode: mode,
      repeat: android && repeat,
      wifiOnly: wifiOnly,
      chargingOnly: chargingOnly,
    );
    await journal.save(pair);
    pairs.add(pair);
    _schedule();
    _notify();
  }

  Future<void> forget(FolderPair pair) async {
    await pause();
    await journal.forget(pair.id);
    pairs.removeWhere((value) => value.id == pair.id);
    _schedule();
    _notify();
  }

  Future<void> reconnect(FolderPair pair) async {
    if (_running != null || _accountKey != pair.account) return;
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
    _schedule();
    _notify();
  }

  void setForeground(bool value) {
    _foreground = value;
    if (!value) {
      _stop = true;
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !_foreground || !android || !pairs.any((p) => p.repeat)) {
      return;
    }
    _timer = Timer(const Duration(minutes: 15), () async {
      for (final pair in List.of(pairs)) {
        if (!_foreground || _disposed || _accountKey != pair.account) break;
        if (pair.repeat && activeId == null) await run(pair);
      }
      _schedule();
    });
  }

  Future<void> pause() async {
    _stop = true;
    await _running;
  }

  Future<void> disconnect() async {
    _foreground = false;
    _timer?.cancel();
    await pause();
    for (final pair in pairs) {
      pair.repeat = false;
      await journal.save(pair);
    }
    pairs = [];
    _owner = null;
    _notify();
  }

  Future<void> run(FolderPair pair) async {
    if (_running != null || _disposed || !_foreground) return;
    final session = account();
    if (session == null || syncAccount(session) != pair.account) return;
    _stop = false;
    activeId = pair.id;
    error = null;
    transferred = conflicts = 0;
    _notify();
    final task = _sync(session, pair);
    _running = task;
    try {
      await task;
      pair.lastRun = DateTime.now();
      await journal.save(pair);
      phase = 'Up to date · no files deleted';
    } on SyncStopped {
      phase = 'Paused · completed transfers are saved';
    } on Object catch (e) {
      error = switch (e) {
        CloudException() => e.message,
        FormatException() => e.message,
        MissingPluginException() =>
          'The native folder-sync service is unavailable. Install the latest ncloud build '
              'and fully restart the app. Reconnecting the folder will not fix this.',
        PlatformException() => switch (e.code) {
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
      activeId = null;
      _running = null;
      _schedule();
      _notify();
    }
  }

  void _check(FolderPair pair) {
    if (_stop || _disposed || !_foreground || _accountKey != pair.account) {
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
    _check(pair);
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
      for (final item in await access.list(pair.folder.token, path)) {
        final child = [...path, item.name];
        checkSyncPath(child);
        if (child.length > 64 || local.length > 100000) {
          throw const FormatException(
            'This pair exceeds the supported scan size.',
          );
        }
        if (item.directory) {
          directories.add(child);
        } else {
          if (item.modified <= 0) {
            throw const FormatException(
              'The folder provider supplies no file modification date.',
            );
          }
          local[_key(child)] = (child, item);
        }
      }
    }
    directories.add([]);
    phase = 'Reading Nextcloud destination';
    _notify();
    while (directories.isNotEmpty) {
      _check(pair);
      if (++scanned > 200000) {
        throw const FormatException(
          'This pair exceeds the supported scan size.',
        );
      }
      final path = directories.removeLast();
      for (final item in await client.listFiles(session, [
        ...pair.remote,
        ...path,
      ])) {
        // Never follow a server listing outside the requested direct children.
        final expected = [...pair.remote, ...path, item.name];
        checkSyncPath(expected);
        if (_key(expected) != _key(item.path) || item.albumDavPath != null) {
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
          directories.add(child);
        } else {
          _remoteVersion(item);
          remote[_key(child)] = (child, item);
        }
      }
    }
    if (pair.mode != SyncMode.download) {
      for (final (path, file) in local.values.toList()) {
        _check(pair);
        final receipt = await journal.receipt(pair.id, 'local', path);
        if (receipt != null && receipt['version'] == file.version) {
          final target = remote[_key(_target(receipt))];
          if (target != null &&
              _remoteVersion(target.$2) == receipt['target_version']) {
            continue;
          }
        }
        var target = path;
        if (remote.containsKey(_key(target))) {
          target = _conflict(path, 'device');
        }
        await _conditions(pair);
        phase = 'Uploading ${file.name}';
        _notify();
        File? staged;
        try {
          staged = await access.export(pair.folder.token, path, file);
          _check(pair);
          if (await staged.length() != file.size) {
            throw const FormatException(
              'The source changed while preparing it. Run again.',
            );
          }
          await _ensureRemote(session, pair, target);
          _check(pair);
          await client.upload(
            session,
            [...pair.remote, ...target],
            staged.openRead(),
            file.size,
          );
          final confirmed =
              (await client.listFiles(session, [
                    ...pair.remote,
                    ...target.take(target.length - 1),
                  ]))
                  .where(
                    (item) => item.name == target.last && !item.isDirectory,
                  )
                  .single;
          if (confirmed.size != file.size) {
            throw const FormatException(
              'Upload size was not confirmed. Run again to reconcile.',
            );
          }
          final version = _remoteVersion(confirmed);
          await journal.confirm(pair.id, path, file.version, target, version);
          remote[_key(target)] = (target, confirmed);
          transferred++;
        } finally {
          if (staged != null) await access.discard(staged);
        }
      }
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
    var parent = List.of(pair.remote);
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
    _timer?.cancel();
    unawaited(
      (_running ?? Future<void>.value()).then((_) async {
        await _loading;
        await journal.close();
      }, onError: (Object _, StackTrace _) => journal.close()),
    );
    super.dispose();
  }
}
