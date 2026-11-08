import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' show DatabaseFactory, DatabaseException;

import 'file_store.dart';
import 'library_database.dart';
import '../../models.dart';

String cacheFailureMessage(String operation, Object error) {
  if (error is DatabaseException) {
    final code = error.getResultCode();
    final primary = code == null ? null : code & 0xff;
    final reason = switch (primary) {
      13 => 'Device storage is full. Free some space and retry.',
      5 ||
      6 => 'The local database is busy. Retry after the current operation.',
      8 => 'The local database is read-only. Check app storage permissions.',
      10 => 'A device storage I/O error prevented the database write.',
      _ => 'A local database operation failed.',
    };
    return 'Could not $operation. $reason '
        '(SQLite ${code ?? 'unknown'}). Saved offline originals are unaffected.';
  }
  if (error is FileSystemException) {
    return 'Could not $operation. '
        '${error.osError?.errorCode == 28 ? 'Device storage is full.' : 'Cannot access app cache storage; check free space and permissions.'}';
  }
  if (error is MissingPluginException) {
    return 'Could not $operation. The local database service is unavailable. Restart the app.';
  }
  return 'Could not $operation. Local cache failure (${error.runtimeType}). '
      'Saved offline originals are unaffected.';
}

/// Stable 128-bit FNV-1a digest used only to derive cache file names.
String cacheDigest(String value) {
  final bytes = utf8.encode(value);
  var a = 0xcbf29ce484222325;
  var b = 0x84222325cbf29ce4;
  for (final byte in bytes) {
    a = (a ^ byte) * 0x100000001b3;
    b = (b ^ (byte + 0x9e)) * 0x100000001b3;
  }
  String hex(int v) =>
      (v >>> 32).toRadixString(16).padLeft(8, '0') +
      (v & 0xffffffff).toRadixString(16).padLeft(8, '0');
  return '${hex(a)}${hex(b)}';
}

/// Bounded browsing cache, separate from user-requested offline downloads.
class LocalCache {
  LocalCache(
    this._locate, {
    Future<Directory> Function()? locateDownloads,
    DatabaseFactory? databaseFactory,
    this.budget = browsingBudget,
  }) : _locateDownloads = locateDownloads,
       _databaseFactory = databaseFactory;

  factory LocalCache.platform() => LocalCache(
    () async => Directory(
      '${(await getApplicationCacheDirectory()).path}/ncloud-cache',
    ),
    locateDownloads: () async => Directory(
      '${(await getApplicationSupportDirectory()).path}/ncloud-downloads',
    ),
  );

  final Future<Directory> Function() _locate;
  final Future<Directory> Function()? _locateDownloads;
  final DatabaseFactory? _databaseFactory;
  LibraryDatabase? _database;
  final int budget;
  Directory? _directory;
  Future<Directory>? _downloadsDirectory;
  Future<void> _writes = Future.value();
  Map<String, ({int size, DateTime accessed})>? _entries;
  int _totalBytes = 0;
  String? _writeError;
  String? get writeError => _writeError;
  void Function(String message)? onWriteError;

  void _reportWriteError(String message) {
    _writeError = message;
    onWriteError?.call(message);
  }

  Future<Directory> get _root async => _directory ??= await _locate();
  static const browsingBudget = 500 * 1024 * 1024;

  Future<Directory> get _downloads =>
      _downloadsDirectory ??= _initializeDownloads().catchError((Object error) {
        _downloadsDirectory = null;
        throw error;
      });

  Future<Directory> _initializeDownloads() async {
    final destination = _locateDownloads == null
        ? Directory('${(await _root).path}-downloads')
        : await _locateDownloads();
    await destination.create(recursive: true);
    return destination;
  }

  Future<T> _serialized<T>(Future<T> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<LibraryDatabase> get _db async => _database ??= LibraryDatabase(
    '${(await _root).path}/catalogue.sqlite3',
    factory: _databaseFactory,
    onError: _reportWriteError,
    prepareStorage: _reserveMetadataSpace,
    reclaimStorage: _reclaimMetadataSpace,
  );

  Future<LibraryDatabase?> get _existingDatabase async {
    final path = '${(await _root).path}/catalogue.sqlite3';
    return await File(path).exists() ? await _db : null;
  }

  Future<void> _index() async {
    if (_entries != null) return;
    final entries = <String, ({int size, DateTime accessed})>{};
    final root = await _root;
    for (final name in ['thumbs']) {
      final folder = Directory('${root.path}/$name');
      if (!await folder.exists()) continue;
      await for (final entity in folder.list()) {
        if (entity is! File) continue;
        if (entity.path.endsWith('.part')) {
          await entity.delete();
          continue;
        }
        final stat = await entity.stat();
        entries[entity.path] = (size: stat.size, accessed: stat.modified);
      }
    }
    _entries = entries;
    _totalBytes = entries.values.fold(0, (total, entry) => total + entry.size);
  }

  int get _metadataReserve => (budget ~/ 10).clamp(1, 16 * 1024 * 1024);

  Future<bool> _reclaimMetadataSpace(int attempt) async =>
      await _evictThumbnails(
        attempt == 2 ? _totalBytes : _metadataReserve * (attempt == 0 ? 1 : 4),
      ) >
      0;

  Future<int> _evictThumbnails(int bytes, {String? protectedPath}) async {
    if (bytes <= 0) return 0;
    await _index();
    final prefix = '${(await _root).path}/thumbs/';
    final entries = _entries!;
    final oldest =
        entries.keys
            .where((path) => path.startsWith(prefix) && path != protectedPath)
            .toList()
          ..sort(
            (a, b) => entries[a]!.accessed.compareTo(entries[b]!.accessed),
          );
    var freed = 0;
    for (final path in oldest) {
      if (freed >= bytes) break;
      final file = File(path);
      if (await file.exists()) await file.delete();
      final size = entries.remove(path)!.size;
      freed += size;
      _totalBytes -= size;
    }
    return freed;
  }

  Future<void> _reserveMetadataSpace({
    int incomingBytes = 0,
    String? protectedPath,
  }) async {
    await _index();
    final databaseBytes = await _database?.allocatedBytes() ?? 0;
    await _evictThumbnails(
      _totalBytes + databaseBytes + incomingBytes + _metadataReserve - budget,
      protectedPath: protectedPath,
    );
  }

  void _touch(File file) {
    final now = DateTime.now();
    final entry = _entries?[file.path];
    if (entry != null &&
        now.difference(entry.accessed) < const Duration(minutes: 5)) {
      return;
    }
    if (entry != null) _entries![file.path] = (size: entry.size, accessed: now);
    unawaited(file.setLastModified(now).catchError((_) => file));
  }

  /// Writes a thumbnail, first evicting the oldest ones down to 80% of the
  /// budget when it would not leave the metadata reserve, so a full cache
  /// does not evict on every write. A write that cannot fit at all is trimmed.
  Future<void> _write(File file, List<int> bytes) async {
    await _index();
    final incoming = bytes.length - (_entries![file.path]?.size ?? 0);
    final used = _totalBytes + (await _database?.allocatedBytes() ?? 0);
    if (used + incoming + _metadataReserve > budget) {
      await _evictThumbnails(
        used + incoming - (budget * 0.8).floor(),
        protectedPath: file.path,
      );
    }
    final temp = File('${file.path}.part');
    try {
      await temp.writeAsBytes(bytes);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    _totalBytes += bytes.length - (_entries![file.path]?.size ?? 0);
    _entries![file.path] = (size: bytes.length, accessed: DateTime.now());
    if (used + incoming > budget) await _trim();
  }

  Future<Directory> _folder(String name) async {
    final dir = Directory('${(await _root).path}/$name');
    await dir.create(recursive: true);
    return dir;
  }

  Future<void> removeThumbnail(String key) => _serialized(() async {
    await _index();
    final file = await _file('thumbs', key);
    if (await file.exists()) await file.delete();
    final entry = _entries!.remove(file.path);
    if (entry != null) _totalBytes -= entry.size;
  });

  Future<File> _file(String folder, String key) async =>
      File('${(await _folder(folder)).path}/${cacheDigest(key)}');

  Future<File> _existingFile(String folder, String key) async =>
      File('${(await _root).path}/$folder/${cacheDigest(key)}');

  static const _thumbMagic = [0x4e, 0x43, 0x54, 0x31]; // NCT1

  /// Cached thumbnail and the file version (etag) it was rendered from, so
  /// it can be shown instantly and refreshed only if the file changed.
  Future<({Uint8List bytes, String version})?> readThumbnail(String key) async {
    try {
      final file = await _existingFile('thumbs', key);
      final data = await file.readAsBytes();
      _touch(file);
      if (data.length < 5 ||
          List.generate(4, (i) => data[i]).join() != _thumbMagic.join()) {
        return null;
      }
      final start = 5 + data[4];
      if (data.length <= start) return null;
      return (
        bytes: Uint8List.sublistView(data, start),
        version: utf8.decode(data.sublist(5, start)),
      );
    } on Object {
      return null;
    }
  }

  Future<void> writeThumbnail(
    String key,
    Uint8List bytes, {
    String version = '',
  }) => _serialized(() async {
    try {
      var tag = utf8.encode(version);
      if (tag.length > 255) tag = tag.sublist(0, 255);
      final file = await _file('thumbs', key);
      final data = BytesBuilder(copy: false)
        ..add(_thumbMagic)
        ..add([tag.length])
        ..add(tag)
        ..add(bytes);
      await _write(file, data.takeBytes());
    } on Object {
      _reportWriteError(
        'Could not save previews. Check available device storage.',
      );
    }
  });

  Future<List<CloudFile>?> readListing(String key) => _serialized(() async {
    try {
      final existing = await _existingDatabase;
      return await existing?.readListing(key);
    } on Object {
      _reportWriteError(
        'Could not read the local library catalogue. Reconnect to reload metadata.',
      );
      return null;
    }
  });

  Future<void> writeListing(String key, List<CloudFile> files) =>
      _serialized(() async {
        try {
          await (await _db).writeListing(key, files);
          await _index();
          await _trim();
        } catch (e) {
          _reportWriteError(cacheFailureMessage('save library pages', e));
        }
      });

  Future<Map<String, dynamic>?> readDocument(String key) =>
      _serialized(() async {
        try {
          final existing = await _existingDatabase;
          return await existing?.readDocument(key);
        } catch (e) {
          _reportWriteError(
            cacheFailureMessage('read the local library catalogue', e),
          );
          return null;
        }
      });

  Future<void> writeDocument(String key, Map<String, dynamic> value) =>
      _serialized(() async {
        try {
          await (await _db).writeDocument(key, value);
          await _index();
          await _trim();
        } catch (e) {
          _reportWriteError(cacheFailureMessage('save library metadata', e));
        }
      });

  /// Persists only mutations since the previous successful transaction; no
  /// whole-library JSON snapshot is created on the UI isolate.
  Future<void> writeLibrary(String key, FileStore store) =>
      _serialized(() async {
        try {
          final db = await _db;
          final full = !await db.containsCollection(key);
          final changes = store.persistenceChanges(full: full);
          await db.writeLibrary(key, changes);
          store.acknowledgePersistence(changes);
          await _index();
          await _trim();
        } catch (e) {
          _reportWriteError(cacheFailureMessage('save library metadata', e));
        }
      });

  Future<List<CloudFile>> readFilesByIds(
    String accountKey,
    Iterable<String> ids,
  ) => _serialized(() async {
    try {
      final db = await _existingDatabase;
      return await db?.readFilesByIds(accountKey, ids) ?? [];
    } on Object {
      _reportWriteError('Could not read the local library catalogue.');
      return <CloudFile>[];
    }
  });

  /// Reads at most [FileStore.maxFiles] persisted day rows, newest day first.
  /// Freshness and complete-day count checks belong to the owning listing.
  Future<List<CloudFile>> readDayFiles(
    String accountKey,
    List<int> days, {
    DateTime? freshSince,
  }) => _serialized(() async {
    try {
      if (days.isEmpty) return <CloudFile>[];
      final db = await _existingDatabase;
      return await db?.readDayFiles(accountKey, days, freshSince: freshSince) ??
          [];
    } on Object {
      _reportWriteError('Could not read the local library catalogue.');
      return <CloudFile>[];
    }
  });

  Future<({List<CloudFile> files, String? etag, DateTime updated})?>
  readFolderSnapshot(String accountKey, List<String> path) =>
      _serialized(() async {
        try {
          return await (await _existingDatabase)?.readFolderSnapshot(
            accountKey,
            path,
          );
        } on Object {
          _reportWriteError('Could not read the local folder catalogue.');
          return null;
        }
      });

  /// Invalidates reloadable pages and folder etags without discarding the
  /// canonical library, discovery documents, or offline downloads.
  Future<void> invalidateListings(String accountKey) => _serialized(() async {
    try {
      await (await _existingDatabase)?.invalidateListings(accountKey);
    } on Object {
      _reportWriteError('Could not invalidate cached library pages.');
    }
  });

  Future<void> clearDocuments() => _serialized(() async {
    await (await _existingDatabase)?.clearDocuments();
  });

  Future<File> _downloadFile(
    String folder,
    String key, [
    String suffix = '',
  ]) async {
    final directory = Directory('${(await _downloads).path}/$folder');
    await directory.create(recursive: true);
    return File('${directory.path}/${cacheDigest(key)}$suffix');
  }

  Future<List<CloudFile>> readOfflineListing(String key) async {
    final file = await _downloadFile('listings', key, '.json');
    if (!await file.exists()) return [];
    final rows = jsonDecode(await file.readAsString()) as List;
    return [
      for (final row in rows)
        CloudFile.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> writeOfflineListing(String key, List<CloudFile> files) =>
      _serialized(() async {
        await _reserveMetadataSpace();
        for (var attempt = 0; ; attempt++) {
          File? temp;
          try {
            final file = await _downloadFile('listings', key, '.json');
            temp = File('${file.path}.part');
            await temp.writeAsString(
              jsonEncode([for (final f in files) f.toJson()]),
            );
            await temp.rename(file.path);
            return;
          } on FileSystemException catch (error) {
            if (error.osError?.errorCode != 28 ||
                attempt >= 3 ||
                !await _reclaimMetadataSpace(attempt)) {
              rethrow;
            }
          } finally {
            if (temp != null && await temp.exists()) await temp.delete();
          }
        }
      });

  /// Location for a fully downloaded original that can be replayed offline.
  Future<File> original(String key, String name) async {
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 && name.length - dot <= 6
        ? name.substring(dot).replaceAll(RegExp(r'[^A-Za-z0-9.]'), '')
        : '';
    return _downloadFile('originals', key, extension);
  }

  Future<void> trim() => _serialized(() async {
    await _index();
    await _trim();
  });

  Future<void> _trim() async {
    final entries = _entries!;
    final db = await _existingDatabase;
    var databaseBytes = await db?.allocatedBytes() ?? 0;
    if (_totalBytes + databaseBytes <= budget) return;
    if (db != null) {
      await db.checkpoint();
      databaseBytes = await db.allocatedBytes();
      if (_totalBytes + databaseBytes <= budget) return;
    }
    final target = (budget * 0.8).floor();
    await _evictThumbnails(_totalBytes + databaseBytes - target);
    if (_totalBytes + databaseBytes <= target) return;
    final ordered = entries.keys.toList()
      ..sort((a, b) => entries[a]!.accessed.compareTo(entries[b]!.accessed));
    for (final path in ordered) {
      if (_totalBytes + databaseBytes <= target) break;
      final file = File(path);
      if (await file.exists()) await file.delete();
      _totalBytes -= entries.remove(path)!.size;
    }
    if (db != null && _totalBytes + databaseBytes > target) {
      await db.trimToBytes((target - _totalBytes).clamp(0, budget));
      databaseBytes = await db.allocatedBytes();
    }
  }

  Future<int> size() async {
    var total = 0;
    try {
      final root = await _root;
      if (!await root.exists()) return 0;
      for (final name in ['thumbs']) {
        final folder = Directory('${root.path}/$name');
        if (!await folder.exists()) continue;
        await for (final entity in folder.list()) {
          if (entity is File) total += await entity.length();
        }
      }
      total += await (await _existingDatabase)?.allocatedBytes() ?? 0;
    } on Object {
      // Best effort.
    }
    return total;
  }

  Future<int> downloadSize() async {
    var total = 0;
    await for (final entity in (await _downloads).list(recursive: true)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  Future<void> clear() => _serialized(() async {
    await _downloads;
    await _database?.close();
    _database = null;
    final root = await _root;
    if (await root.exists()) {
      await for (final entity in root.list()) {
        if (entity is Directory && entity.path == '${root.path}/originals') {
          continue;
        }
        await entity.delete(recursive: true);
      }
    }
    _entries = null;
    _totalBytes = 0;
    _writeError = null;
  });

  Future<void> close() => _serialized(() async {
    await _database?.close();
    _database = null;
  });

  Future<void> clearAll() async {
    await clear();
    await _serialized(() async {
      final root = await _root;
      final legacyOriginals = Directory('${root.path}/originals');
      if (await legacyOriginals.exists()) {
        await legacyOriginals.delete(recursive: true);
      }
      final downloads = await _downloads;
      if (await downloads.exists()) await downloads.delete(recursive: true);
      _downloadsDirectory = null;
    });
  }
}
