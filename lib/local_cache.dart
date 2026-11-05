import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

Uint8List _encodeMetadata(Object value) {
  final plain = utf8.encode(jsonEncode(value));
  if (plain.length < 4096) return plain;
  final packed = GZipCodec(level: 1).encode(plain);
  return Uint8List.fromList(
    packed.length <= plain.length * 0.9 ? packed : plain,
  );
}

Future<Uint8List> _packMetadata(Object value) =>
    Isolate.run(() => _encodeMetadata(value));

Object? _decodeMetadata(Uint8List bytes) {
  final packed = bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  return jsonDecode(utf8.decode(packed ? gzip.decode(bytes) : bytes));
}

Future<Object?> _readMetadata(File file) async {
  final bytes = await file.readAsBytes();
  return bytes.length >= 4096 ||
          (bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b)
      ? Isolate.run(() => _decodeMetadata(bytes))
      : _decodeMetadata(bytes);
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
    this.budget = browsingBudget,
  }) : _locateDownloads = locateDownloads;

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
    final root = await _root;
    final destination = _locateDownloads == null
        ? Directory('${root.path}-downloads')
        : await _locateDownloads();
    await destination.create(recursive: true);
    final legacy = Directory('${root.path}/originals');
    if (await legacy.exists()) {
      final originals = Directory('${destination.path}/originals');
      await originals.create(recursive: true);
      await for (final entity in legacy.list()) {
        if (entity is! File) continue;
        final target = File(
          '${originals.path}/${entity.uri.pathSegments.last}',
        );
        if (!await target.exists()) {
          final temp = File('${target.path}.part');
          await entity.copy(temp.path);
          await temp.rename(target.path);
        }
        await entity.delete();
      }
    }
    return destination;
  }

  Future<void> _serialized(Future<void> Function() operation) {
    final next = _writes.then((_) => operation());
    _writes = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _index() async {
    if (_entries != null) return;
    final entries = <String, ({int size, DateTime accessed})>{};
    for (final name in ['thumbs', 'listings', 'indexes']) {
      await for (final entity in (await _folder(name)).list()) {
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

  Future<void> _write(File file, List<int> bytes) async {
    await _index();
    final temp = File('${file.path}.part');
    try {
      await temp.writeAsBytes(bytes);
      await temp.rename(file.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
    _totalBytes += bytes.length - (_entries![file.path]?.size ?? 0);
    _entries![file.path] = (size: bytes.length, accessed: DateTime.now());
    await _trim();
  }

  Future<Directory> _folder(String name) async {
    final dir = Directory('${(await _root).path}/$name');
    await dir.create(recursive: true);
    return dir;
  }

  Future<File> _file(String folder, String key, [String suffix = '']) async =>
      File('${(await _folder(folder)).path}/${cacheDigest(key)}$suffix');

  static const _thumbMagic = [0x4e, 0x43, 0x54, 0x31]; // NCT1

  /// Cached thumbnail and the file version (etag) it was rendered from, so
  /// it can be shown instantly and refreshed only if the file changed.
  Future<({Uint8List bytes, String version})?> readThumbnail(String key) async {
    try {
      final file = await _file('thumbs', key);
      if (!await file.exists()) return null;
      final data = await file.readAsBytes();
      _touch(file);
      var version = '';
      var start = 0;
      if (data.length > 5 &&
          List.generate(4, (i) => data[i]).join() == _thumbMagic.join()) {
        final length = data[4];
        if (data.length < 5 + length) return null;
        version = utf8.decode(data.sublist(5, 5 + length));
        start = 5 + length;
      }
      if (data.length <= start) return null;
      return (bytes: Uint8List.sublistView(data, start), version: version);
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

  Future<List<CloudFile>?> readListing(String key) async {
    try {
      final file = await _file('listings', key, '.json');
      if (!await file.exists()) return null;
      final json = (await _readMetadata(file)) as List<dynamic>;
      _touch(file);
      return [
        for (final item in json)
          CloudFile.fromJson((item as Map).cast<String, dynamic>()),
      ];
    } on Object {
      return null;
    }
  }

  Future<void> writeListing(String key, List<CloudFile> files) =>
      _serialized(() async {
        try {
          final file = await _file('listings', key, '.json');
          final rows = [for (final f in files) f.toJson()];
          await _write(file, await _packMetadata(rows));
        } on Object {
          _reportWriteError(
            'Could not save library pages. Check available device storage.',
          );
        }
      });

  Future<Map<String, dynamic>?> readDocument(String key) async {
    try {
      final file = await _file('indexes', key, '.json');
      if (!await file.exists()) return null;
      _touch(file);
      return ((await _readMetadata(file)) as Map).cast<String, dynamic>();
    } on Object {
      return null;
    }
  }

  Future<void> writeDocument(String key, Map<String, dynamic> value) =>
      _serialized(() async {
        try {
          final file = await _file('indexes', key, '.json');
          await _write(file, await _packMetadata(value));
        } on Object {
          _reportWriteError(
            'Could not save library metadata. Check available device storage.',
          );
        }
      });

  Future<void> clearDocuments() => _serialized(() async {
    final folder = await _folder('indexes');
    await for (final entity in folder.list()) {
      if (entity is File) {
        await entity.delete();
        _totalBytes -= _entries?.remove(entity.path)?.size ?? 0;
      }
    }
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
    if (!await file.exists()) {
      final legacy = await readListing(key);
      if (legacy == null) return [];
      await writeOfflineListing(key, legacy);
      return legacy;
    }
    final rows = jsonDecode(await file.readAsString()) as List;
    return [
      for (final row in rows)
        CloudFile.fromJson((row as Map).cast<String, dynamic>()),
    ];
  }

  Future<void> writeOfflineListing(String key, List<CloudFile> files) =>
      _serialized(() async {
        final file = await _downloadFile('listings', key, '.json');
        final temp = File('${file.path}.part');
        await temp.writeAsString(
          jsonEncode([for (final f in files) f.toJson()]),
        );
        await temp.rename(file.path);
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
    if (_totalBytes <= budget) return;
    final ordered = entries.keys.toList()
      ..sort((a, b) => entries[a]!.accessed.compareTo(entries[b]!.accessed));
    for (final path in ordered) {
      if (_totalBytes <= budget * 0.8) break;
      final file = File(path);
      if (await file.exists()) await file.delete();
      _totalBytes -= entries.remove(path)!.size;
    }
  }

  Future<int> size() async {
    var total = 0;
    try {
      final root = await _root;
      if (!await root.exists()) return 0;
      for (final name in ['thumbs', 'indexes', 'listings']) {
        final folder = Directory('${root.path}/$name');
        if (!await folder.exists()) continue;
        await for (final entity in folder.list()) {
          if (entity is File) total += await entity.length();
        }
      }
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
    final root = await _root;
    if (await root.exists()) await root.delete(recursive: true);
    _entries = null;
    _totalBytes = 0;
    _writeError = null;
  });

  Future<void> clearAll() async {
    await clear();
    await _serialized(() async {
      final downloads = await _downloads;
      if (await downloads.exists()) await downloads.delete(recursive: true);
      _downloadsDirectory = null;
    });
  }
}
