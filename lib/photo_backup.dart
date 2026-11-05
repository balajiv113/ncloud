import 'dart:io';

import 'folder_sync.dart';

class PhotoLibraryAccess implements FolderAccess {
  static const channel = NativeFolderAccess.channel;
  final _files = NativeFolderAccess();

  Future<void> openSettings() async {
    if (await channel.invokeMethod<bool>('photos.settings') != true) {
      throw StateError(
        'Could not open device settings. Open ncloud permissions in Settings.',
      );
    }
  }

  Future<String> permission({bool request = false}) async {
    final value = await channel.invokeMethod<String>('photos.permission', {
      'request': request,
    });
    if (!['full', 'limited', 'denied'].contains(value)) {
      throw StateError(
        'The photo library returned an invalid permission status.',
      );
    }
    return value!;
  }

  @override
  Future<List<DeviceEntry>> list(String token, List<String> path) async {
    if (path.isEmpty) {
      final assets = <DeviceEntry>[];
      final ids = <String>{};
      var offset = 0;
      while (true) {
        final page = await channel.invokeListMethod<dynamic>('photos.scan', {
          'offset': offset,
          'limit': 500,
        });
        if (page == null) {
          throw StateError('Photo library did not return a listing.');
        }
        for (final value in page) {
          final item = (value as Map).cast<String, dynamic>();
          if (!ids.add(item['id'] as String)) {
            throw const FormatException(
              'The library changed during scanning. Run backup again.',
            );
          }
          assets.add(
            DeviceEntry(item['id'] as String, true, 0, item['modified'] as int),
          );
        }
        if (assets.length > 100000) {
          throw const FormatException(
            'Photo backup currently supports up to 100,000 assets per run.',
          );
        }
        if (page.length < 500) break;
        offset += page.length;
      }
      return assets;
    }
    if (path.length != 1) {
      throw const FormatException('Invalid photo resource path.');
    }
    final values = await channel.invokeListMethod<dynamic>('photos.resources', {
      'id': path.single,
    });
    if (values == null) throw StateError('Photo resources are unavailable.');
    return [
      for (final value in values)
        DeviceEntry(
          (value as Map)['name'] as String,
          false,
          value['size'] as int,
          value['modified'] as int,
          backupPath: (value['relative'] as List?)?.cast<String>(),
        ),
    ];
  }

  @override
  Future<File> export(
    String token,
    List<String> path,
    DeviceEntry expected,
  ) async {
    if (path.length != 2) {
      throw const FormatException('Invalid photo resource path.');
    }
    final file = await channel.invokeMethod<String>('photos.export', {
      'id': path.first,
      'name': path.last,
      'modified': expected.modified,
      'size': expected.size,
    });
    if (file == null) throw StateError('The photo original is unavailable.');
    return File(file);
  }

  @override
  Future<DeviceFolder?> pick() => throw UnsupportedError(
    'Photos uses library permission, not a folder picker.',
  );
  @override
  Future<File> stage() => _files.stage();
  @override
  Future<void> discard(File staged) => _files.discard(staged);
  @override
  Future<SyncConditions> conditions() => _files.conditions();
  @override
  Future<DeviceEntry> import(String token, List<String> path, File staged) =>
      throw UnsupportedError(
        'Photo backup never writes to the device library.',
      );
}
