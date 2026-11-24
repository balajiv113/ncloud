import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import 'album_folders.dart';
import 'device_library.dart';

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

enum DeviceSourceKind { folder, photoAlbum, library }

class DeviceFolder {
  const DeviceFolder(
    this.token,
    this.name,
    this.identity, {
    this.kind = DeviceSourceKind.folder,
  });

  /// The phone's whole photo and video library, as the folders it has, without
  /// the phone folders in [excluded] (such as `Pictures/Screenshots`). The
  /// identity stays the same, so leaving folders out keeps the backup and what
  /// it has recorded.
  DeviceFolder.library({List<List<String>> excluded = const []})
    : this(
        excluded.isEmpty
            ? libraryToken
            : '$libraryToken:${base64Url.encode(utf8.encode(jsonEncode(excluded)))}',
        'Phone',
        libraryToken,
        kind: DeviceSourceKind.library,
      );

  static const libraryToken = 'library:all';

  /// Whether [token] is the phone's library, with or without folders left out.
  static bool isLibraryToken(String token) =>
      token == libraryToken || token.startsWith('$libraryToken:');

  /// The phone folders left out of a library [token].
  static List<List<String>> excludedFolders(String token) {
    if (!token.startsWith('$libraryToken:')) return const [];
    final values =
        jsonDecode(
              utf8.decode(
                base64Url.decode(token.substring(libraryToken.length + 1)),
              ),
            )
            as List<dynamic>;
    return [
      for (final value in values) (value as List<dynamic>).cast<String>(),
    ];
  }

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
    this.id,
  });
  final String name;
  final bool directory;
  final int size;
  final int modified;
  final String contentType;
  final String? revision;

  /// The provider's own id for the file, when it has one. It lets the file be
  /// opened directly instead of being searched for by name in its folder.
  final String? id;
  String get version => revision ?? '$size|$modified';
}

class SyncConditions {
  const SyncConditions({required this.wifi, required this.charging});
  final bool wifi;
  final bool charging;
}

/// A device that works out each file's SHA-1 while copying it, so the file does
/// not have to be read again to be fingerprinted.
abstract interface class StagedChecksums {
  /// The fingerprint taken while [staged] was copied, or null if there is none.
  Future<String?> checksumOf(File staged);
}

/// A device that can say how many bytes of a copy are done while it runs.
abstract interface class CopyProgress {
  /// Like [FolderAccess.export], calling [onBytes] with the size of the copy so
  /// far while it is being made.
  Future<File> exportTracked(
    String token,
    List<String> path,
    DeviceEntry expected,
    void Function(int bytes) onBytes,
  );
}

abstract interface class FolderAccess {
  Future<DeviceFolder?> pick();
  Future<List<DeviceEntry>> list(String token, List<String> path);
  Future<File> export(String token, List<String> path, DeviceEntry expected);
  Future<File> stage();
  Future<DeviceEntry> import(String token, List<String> path, File staged);
  Future<void> discard(File staged);

  /// Deletes every staged transfer file, such as when the account signs out.
  Future<void> clearStaging();
  Future<SyncConditions> conditions();
}

/// A file to remove from the phone, with the entry it was listed as.
typedef RemovalFile = ({List<String> path, DeviceEntry entry});

/// Sources that can move files to the phone's own trash, after the phone has
/// asked the user. Nothing here is ever called without the user's tap.
abstract interface class RemovableAccess {
  /// Moves [files] of the source [token] to the trash and returns the paths
  /// that were actually removed. Fewer than asked means the user declined.
  Future<List<List<String>>> moveToTrash(String token, List<RemovalFile> files);
}

abstract interface class PhotoAlbumAccess {
  Future<List<DeviceFolder>> albums();
}

class NativeFolderAccess
    implements
        FolderAccess,
        PhotoAlbumAccess,
        LibraryAccess,
        RemovableAccess,
        StagedChecksums,
        CopyProgress {
  static const channel = MethodChannel('app.ncloud/folder_sync');

  /// The library as last listed, so the folders below the top are answered
  /// without asking the phone again.
  LibraryTree? _tree;
  String? _treeToken;

  /// The whole iPhone library with album folders, as last listed.
  AlbumFolderTree? _albumTree;
  String? _albumTreeToken;
  List<List<String>> _skipped = const [];

  @override
  void skipFolders(List<List<String>> folders) => _skipped = folders;

  @override
  Future<LibraryPermission> libraryPermission() async => _permission(
    await channel.invokeMapMethod<String, dynamic>('mediaAccess'),
  );

  @override
  Future<LibraryPermission> requestLibraryPermission() async => _permission(
    await channel.invokeMapMethod<String, dynamic>('mediaRequest'),
  );

  LibraryPermission _permission(Map<String, dynamic>? value) =>
      switch (value?['status']) {
        'granted' => LibraryPermission.granted,
        'partial' => LibraryPermission.partial,
        _ => LibraryPermission.denied,
      };

  /// Every photo and video, read a page at a time so a very large library never
  /// has to cross the channel in one message.
  Future<List<LibraryItem>> _libraryItems() async {
    if (await libraryPermission() == LibraryPermission.denied) {
      throw PlatformException(
        code: 'media_permission',
        message: 'Allow access to photos and videos to back up your library.',
      );
    }
    const page = 2000;
    final byId = <String, LibraryItem>{};
    var offset = 0;
    while (true) {
      final values = await channel.invokeListMethod<dynamic>('mediaList', {
        'offset': offset,
        'limit': page,
      });
      if (values == null) {
        throw StateError('The photo library returned no listing.');
      }
      for (final value in values) {
        final item = LibraryItem.fromMap(value as Map<dynamic, dynamic>);
        byId[item.id] = item;
      }
      offset += values.length;
      if (values.length < page) break;
    }
    return byId.values.toList();
  }

  Future<List<DeviceEntry>> _listLibrary(
    String token,
    List<String> path,
  ) async {
    checkSyncPath(path);
    // The top of the library starts a new look; the folders below reuse it.
    if (path.isEmpty || _tree == null || _treeToken != token) {
      _tree = LibraryTree(
        await _libraryItems(),
        exclude: [..._skipped, ...DeviceFolder.excludedFolders(token)],
      );
      _treeToken = token;
    }
    return _tree!.children(path);
  }

  @override
  Future<List<LibraryFolder>> libraryFolders() async =>
      LibraryTree(await _libraryItems()).folders;

  Future<File> _exportLibrary(
    List<String> path,
    DeviceEntry expected, [
    File? into,
  ]) async {
    checkSyncPath(path);
    final id = expected.id ?? _tree?.file(path)?.id;
    if (id == null) {
      throw StateError('That photo is no longer in the library. Scan again.');
    }
    return _staged(
      await channel.invokeMethod<Object>('mediaExport', {
        'id': id,
        'size': expected.size,
        'modified': expected.modified,
        if (into != null) 'into': into.path,
      }),
    );
  }

  /// Fingerprints taken while files were copied, by the path of the copy.
  final Map<String, String> _checksums = {};

  /// Reads what a native copy returned: the path, and the SHA-1 when it came
  /// with one.
  File _staged(Object? result) {
    final String? path;
    String? sha1;
    if (result is Map) {
      path = result['path'] as String?;
      final value = result['sha1'];
      if (value is String && RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
        sha1 = value;
      }
    } else {
      path = result as String?;
    }
    if (path == null) throw StateError('Could not prepare the source file.');
    if (sha1 != null) _checksums[path] = sha1;
    return File(path);
  }

  @override
  Future<String?> checksumOf(File staged) async => _checksums[staged.path];

  @override
  Future<List<List<String>>> moveToTrash(
    String token,
    List<RemovalFile> files,
  ) async {
    if (files.isEmpty) return const [];
    if (DeviceFolder.isLibraryToken(token)) {
      final paths = <String, List<String>>{};
      for (final f in files) {
        final id = f.entry.id ?? _tree?.file(f.path)?.id;
        if (id == null) {
          throw StateError(
            'That photo is no longer in the library. Scan again.',
          );
        }
        paths[id] = f.path;
      }
      final removed = await channel.invokeListMethod<String>('mediaTrash', {
        'ids': paths.keys.toList(),
      });
      return [
        for (final id in removed ?? const <String>[])
          if (paths[id] != null) paths[id]!,
      ];
    }
    if (token.startsWith('photoset:') || token.startsWith('photos:')) {
      // Every photo of the whole library is known under the library's own
      // listing, which a combined listing keeps current.
      final names = {for (final f in files) f.path.last: f.path};
      final removed = await channel.invokeListMethod<String>('deleteListed', {
        'token': token.startsWith('photoset:') ? cameraRollToken : token,
        'path': const <String>[],
        'names': names.keys.toList(),
      });
      return [
        for (final name in removed ?? const <String>[])
          if (names[name] != null) names[name]!,
      ];
    }
    throw UnsupportedError('Removing files is not available for this source.');
  }

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
    id: value['id'] as String?,
  );

  @override
  Future<List<DeviceEntry>> list(String token, List<String> path) async {
    if (DeviceFolder.isLibraryToken(token)) return _listLibrary(token, path);
    if (token.startsWith('photoset:')) return _listAlbumFolders(token, path);
    return _nativeList(token, path);
  }

  Future<List<DeviceEntry>> _nativeList(String token, List<String> path) async {
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

  /// Lists the library once for each chosen album and once for everything,
  /// and gives every photo to the first album that holds it. The listing is
  /// read again whenever the top is listed, which is where a run starts.
  Future<List<DeviceEntry>> _listAlbumFolders(
    String token,
    List<String> path,
  ) async {
    if (path.isEmpty || _albumTree == null || _albumTreeToken != token) {
      final albums = albumsOf(token)!;
      final lists = <List<DeviceEntry>>[];
      final kept = <AlbumChoice>[];
      for (final album in albums) {
        try {
          lists.add(await _nativeList(album.token, const []));
          kept.add(album);
        } on PlatformException catch (error) {
          // An album that was deleted on the phone has nothing to back up; its
          // photos are listed with the rest. Anything else is a real problem.
          if (error.code != 'photos_album') rethrow;
        }
      }
      // Photos in the albums to leave out. An album that cannot be read must
      // stop the run, or its photos would be uploaded after all; one that was
      // deleted on the phone has nothing to leave out.
      final left = <List<DeviceEntry>>[];
      for (final album in excludedOf(token)) {
        try {
          left.add(await _nativeList(album.token, const []));
        } on PlatformException catch (error) {
          if (error.code != 'photos_album') rethrow;
        }
      }
      final library = await _nativeList(cameraRollToken, const []);
      _albumTree = AlbumFolderTree(kept, lists, library, excluded: left);
      _albumTreeToken = token;
    }
    return _albumTree!.children(path);
  }

  @override
  Future<File> export(String token, List<String> path, DeviceEntry expected) =>
      _export(token, path, expected, null);

  @override
  Future<File> exportTracked(
    String token,
    List<String> path,
    DeviceEntry expected,
    void Function(int bytes) onBytes,
  ) async {
    // The copy is made into a file whose name is known in advance, so its size
    // can be read while the phone is still writing it.
    final File into;
    try {
      into = await stage();
    } on Object {
      return _export(token, path, expected, null);
    }
    var reading = false;
    final timer = Timer.periodic(const Duration(milliseconds: 300), (_) async {
      if (reading) return;
      reading = true;
      try {
        onBytes(await into.length());
      } on Object {
        // The file may not exist yet, or be gone.
      } finally {
        reading = false;
      }
    });
    try {
      final made = await _export(token, path, expected, into);
      if (made.path != into.path) await discard(into);
      return made;
    } on Object {
      await discard(into);
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  Future<File> _export(
    String token,
    List<String> path,
    DeviceEntry expected,
    File? into,
  ) async {
    if (DeviceFolder.isLibraryToken(token)) {
      return _exportLibrary(path, expected, into);
    }
    if (token.startsWith('photoset:')) {
      final tree = _albumTree;
      if (tree == null || _albumTreeToken != token) {
        throw StateError('The photo library changed. Scan again.');
      }
      return _exportNative(
        tree.tokenFor(path) ?? cameraRollToken,
        [path.last],
        expected,
        into,
      );
    }
    return _exportNative(token, path, expected, into);
  }

  Future<File> _exportNative(
    String token,
    List<String> path,
    DeviceEntry expected, [
    File? into,
  ]) async {
    checkSyncPath(path);
    return _staged(
      await channel.invokeMethod<Object>('export', {
        'token': token,
        'path': path,
        'size': expected.size,
        'modified': expected.modified,
        'version': expected.version,
        if (expected.id != null) 'id': expected.id,
        if (into != null) 'into': into.path,
      }),
    );
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
  Future<void> discard(File staged) {
    _checksums.remove(staged.path);
    return channel.invokeMethod<void>('discard', {'staged': staged.path});
  }

  @override
  Future<void> clearStaging() => channel.invokeMethod<void>('clearStaging');
}
