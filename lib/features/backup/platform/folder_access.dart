import 'dart:io';

import 'package:flutter/services.dart';

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

  /// The phone's whole photo and video library, as the folders it has.
  const DeviceFolder.library()
    : this(libraryToken, 'Phone', libraryToken, kind: DeviceSourceKind.library);

  static const libraryToken = 'library:all';

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

abstract interface class PhotoAlbumAccess {
  Future<List<DeviceFolder>> albums();
}

class NativeFolderAccess
    implements FolderAccess, PhotoAlbumAccess, LibraryAccess {
  static const channel = MethodChannel('app.ncloud/folder_sync');

  /// The library as last listed, so the folders below the top are answered
  /// without asking the phone again.
  LibraryTree? _tree;
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

  Future<List<DeviceEntry>> _listLibrary(List<String> path) async {
    checkSyncPath(path);
    // The top of the library starts a new look; the folders below reuse it.
    if (path.isEmpty || _tree == null) {
      _tree = LibraryTree(await _libraryItems(), exclude: _skipped);
    }
    return _tree!.children(path);
  }

  Future<File> _exportLibrary(List<String> path, DeviceEntry expected) async {
    checkSyncPath(path);
    final id = expected.id ?? _tree?.file(path)?.id;
    if (id == null) {
      throw StateError('That photo is no longer in the library. Scan again.');
    }
    final file = await channel.invokeMethod<String>('mediaExport', {
      'id': id,
      'size': expected.size,
      'modified': expected.modified,
    });
    if (file == null) throw StateError('Could not prepare the source file.');
    return File(file);
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
    if (token == DeviceFolder.libraryToken) return _listLibrary(path);
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
    if (token == DeviceFolder.libraryToken) {
      return _exportLibrary(path, expected);
    }
    checkSyncPath(path);
    final file = await channel.invokeMethod<String>('export', {
      'token': token,
      'path': path,
      'size': expected.size,
      'modified': expected.modified,
      'version': expected.version,
      if (expected.id != null) 'id': expected.id,
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

  @override
  Future<void> clearStaging() => channel.invokeMethod<void>('clearStaging');
}
