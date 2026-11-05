import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

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

/// Disk cache for thumbnails, library listings and played videos so the app
/// opens instantly and reruns avoid repeated network transfers.
class LocalCache {
  LocalCache(this._locate);

  factory LocalCache.platform() => LocalCache(
    () async => Directory(
      '${(await getApplicationCacheDirectory()).path}/ncloud-cache',
    ),
  );

  final Future<Directory> Function() _locate;
  Directory? _directory;

  Future<Directory> get _root async => _directory ??= await _locate();
  static const thumbnailBudget = 256 * 1024 * 1024;
  static const videoBudget = 1024 * 1024 * 1024;
  int _writesSinceTrim = 0;

  Future<Directory> _folder(String name) async {
    final dir = Directory('${(await _root).path}/$name');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String folder, String key, [String suffix = '']) async =>
      File('${(await _folder(folder)).path}/${cacheDigest(key)}$suffix');

  Future<Uint8List?> readThumbnail(String key) async {
    try {
      final file = await _file('thumbs', key);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return null;
      unawaited(file.setLastModified(DateTime.now()).catchError((_) {}));
      return bytes;
    } on Object {
      return null;
    }
  }

  Future<void> writeThumbnail(String key, Uint8List bytes) async {
    try {
      final file = await _file('thumbs', key);
      final temp = File('${file.path}.part');
      await temp.writeAsBytes(bytes, flush: false);
      await temp.rename(file.path);
      if (++_writesSinceTrim >= 200) {
        _writesSinceTrim = 0;
        await trim();
      }
    } on Object {
      // Cache failures never block browsing.
    }
  }

  Future<List<CloudFile>?> readListing(String key) async {
    try {
      final file = await _file('listings', key, '.json');
      if (!await file.exists()) return null;
      final json = jsonDecode(await file.readAsString()) as List<dynamic>;
      return [
        for (final item in json)
          CloudFile.fromJson((item as Map).cast<String, dynamic>()),
      ];
    } on Object {
      return null;
    }
  }

  Future<void> writeListing(String key, List<CloudFile> files) async {
    try {
      final file = await _file('listings', key, '.json');
      final temp = File('${file.path}.part');
      await temp.writeAsString(jsonEncode([for (final f in files) f.toJson()]));
      await temp.rename(file.path);
    } on Object {
      // Cache failures never block browsing.
    }
  }

  Future<Map<String, dynamic>?> readDocument(String key) async {
    try {
      final file = await _file('indexes', key, '.json');
      if (!await file.exists()) return null;
      return (jsonDecode(await file.readAsString()) as Map)
          .cast<String, dynamic>();
    } on Object {
      return null;
    }
  }

  Future<void> writeDocument(String key, Map<String, dynamic> value) async {
    try {
      final file = await _file('indexes', key, '.json');
      final temp = File('${file.path}.part');
      await temp.writeAsString(jsonEncode(value));
      await temp.rename(file.path);
    } on Object {
      // Optional indexes are rebuilt from the server if storage is unavailable.
    }
  }

  Future<void> clearDocuments() async {
    final folder = await _folder('indexes');
    await for (final entity in folder.list()) {
      if (entity is File) await entity.delete();
    }
  }

  /// Location for a fully downloaded original that can be replayed offline.
  Future<File> original(String key, String name) async {
    final dot = name.lastIndexOf('.');
    final extension = dot > 0 && name.length - dot <= 6
        ? name.substring(dot).replaceAll(RegExp(r'[^A-Za-z0-9.]'), '')
        : '';
    return _file('originals', key, extension);
  }

  Future<void> trim() async {
    await _trimFolder('thumbs', thumbnailBudget);
    await _trimFolder('originals', videoBudget);
  }

  Future<void> _trimFolder(String name, int budget) async {
    try {
      final entries = <(File, FileStat)>[];
      await for (final entity in (await _folder(name)).list()) {
        if (entity is File) entries.add((entity, await entity.stat()));
      }
      var total = entries.fold<int>(0, (sum, e) => sum + e.$2.size);
      if (total <= budget) return;
      entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
      for (final (file, stat) in entries) {
        if (total <= budget * 0.8) break;
        await file.delete();
        total -= stat.size;
      }
    } on Object {
      // Best effort.
    }
  }

  Future<int> size() async {
    var total = 0;
    try {
      final root = await _root;
      if (!await root.exists()) return 0;
      await for (final entity in root.list(recursive: true)) {
        if (entity is File) total += await entity.length();
      }
    } on Object {
      // Best effort.
    }
    return total;
  }

  Future<void> clear() async {
    try {
      final root = await _root;
      if (await root.exists()) await root.delete(recursive: true);
    } on Object {
      // Nothing cached or the platform has no cache directory.
    }
  }
}
