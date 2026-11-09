import 'dart:io';

import 'package:flutter/services.dart';

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

  /// Deletes every staged transfer file, such as when the account signs out.
  Future<void> clearStaging();
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

  @override
  Future<void> clearStaging() => channel.invokeMethod<void>('clearStaging');
}
