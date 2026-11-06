import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/file_store.dart';
import 'package:ncloud/folder_sync.dart';
import 'package:ncloud/library_screen.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';

import '../test/app_test.dart' show MemoryStore;
import '../test/folder_sync_test.dart' show CloudFolders;
import '../test/nextcloud_client_test.dart'
    show account, multistatus, responseEntry;

Future<void> main() async {
  late AppController controller;
  late LocalCache cache;
  late Directory cacheRoot;
  enableFlutterDriverExtension(
    handler: (message) async {
      if (message == 'driveState') {
        return jsonEncode({
          'directory': controller.directory.join('/'),
          'items': controller.items.map((f) => f.path.join('/')).toList()
            ..sort(),
        });
      }
      if (message == 'testAlbum') return _testRealAlbum();
      if (message == 'close') {
        controller.dispose();
        await cache.close();
        await cacheRoot.delete(recursive: true);
        return 'closed';
      }
      throw ArgumentError.value(
        message,
        'message',
        'Unknown iOS test operation',
      );
    },
  );
  const root = '/nextcloud/remote.php/dav/files/alice';
  String folder(String path) => responseEntry(href: '$root/$path/')
      .replaceFirst(
        '<d:resourcetype/>',
        '<d:resourcetype><d:collection/></d:resourcetype>',
      )
      .replaceFirst('image/jpeg', 'httpd/unix-directory')
      .replaceFirst('</d:prop>', '<d:getetag>"folder-v1"</d:getetag></d:prop>');
  final client = NextcloudClient(
    transport: MockClient((request) async {
      if (request.method != 'PROPFIND') return http.Response('', 404);
      final nested = request.url.path.endsWith('/Trips');
      return http.Response(
        multistatus(
          nested
              ? folder('Unrelated') +
                    folder('Trips') +
                    folder('Trips/Summer') +
                    folder('Trips/Summer') +
                    folder('Trips/Summer/Summer') +
                    folder('Other/Summer')
              : folder('Trips') +
                    folder('Trips') +
                    folder('Other') +
                    folder('Trips/Summer'),
        ),
        207,
      );
    }),
  );
  cacheRoot = await Directory.systemTemp.createTemp('ncloud-ios-drive-');
  cache = LocalCache(() async => cacheRoot);
  await cache.writeLibrary(
    'library-v1|${account.server}|${account.userId}',
    FileStore()..putFolder(
      ['Trips'],
      [
        const CloudFile(
          path: ['Other', 'Summer'],
          name: 'Summer',
          isDirectory: true,
          id: 'invalid-snapshot',
        ),
      ],
      etag: '"folder-v1"',
    ),
  );
  controller = AppController(store: MemoryStore(), client: client, cache: cache)
    ..account = account
    ..tab = 1;
  await controller.load();
  runApp(
    MaterialApp(
      home: ListenableBuilder(
        listenable: controller,
        builder: (_, _) => LibraryScreen(controller: controller),
      ),
    ),
  );
}

void _require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<T> _stage<T>(String name, Future<T> Function() action) async {
  debugPrint('iOS album integration: $name');
  final value = await action().timeout(
    const Duration(seconds: 30),
    onTimeout: () => throw StateError('iOS album integration timed out: $name'),
  );
  debugPrint('iOS album integration completed: $name');
  return value;
}

Future<String> _testRealAlbum() async {
  _require(Platform.isIOS, 'This integration test requires iOS.');
  final access = NativeFolderAccess();
  final albums = await _stage('enumerating albums', access.albums);
  DeviceFolder? selected;
  DeviceEntry? original;
  for (final album in albums) {
    final entries = await _stage(
      'listing ${album.name}',
      () => access.list(album.token, []),
    );
    final probes = entries.where(
      (entry) => entry.name.startsWith('ncloud-probe'),
    );
    if (probes.isNotEmpty) {
      selected = album;
      original = probes.first;
      break;
    }
  }
  _require(
    selected != null && original != null,
    'CI must seed a photo and grant Full Photos Access.',
  );
  final folder = selected!;
  final source = original!;
  _require(
    folder.kind == DeviceSourceKind.photoAlbum &&
        source.size == -1 &&
        source.revision?.isNotEmpty == true,
    'PhotoKit must provide a revisioned album original.',
  );
  final staged = await _stage(
    'exporting the seeded original',
    () => access.export(folder.token, [source.name], source),
  );
  late List<int> bytes;
  try {
    bytes = await staged.readAsBytes();
    _require(bytes.isNotEmpty, 'PhotoKit original export was empty.');
  } finally {
    await access.discard(staged);
  }
  final temp = await Directory.systemTemp.createTemp('ncloud-ios-integration-');
  final journal = SyncJournal(path: '${temp.path}/journal.sqlite3');
  final cloud = CloudFolders();
  final sync = FolderSyncController(
    client: cloud,
    account: () => account,
    access: access,
    journal: journal,
  );
  try {
    await _stage('opening the journal', sync.load);
    await _stage(
      'saving the album pair',
      () => sync.add(
        'Simulator album',
        folder,
        ['Backup'],
        SyncMode.backup,
        false,
        wifiOnly: false,
      ),
    );
    final pair = sync.pairs.single;
    await _stage('uploading the album', () => sync.run(pair));
    _require(sync.error == null, 'Real iOS album upload failed: ${sync.error}');
    final uploadedBytes =
        cloud.files[['Backup', folder.name, source.name].join('/')]?.$1;
    _require(
      jsonEncode(uploadedBytes) == jsonEncode(bytes),
      'Uploaded original bytes differ from the real PhotoKit export.',
    );
    final uploaded = cloud.uploads;
    _require(uploaded > 0, 'No album originals were uploaded.');
    await _stage('checking unchanged receipts', () => sync.run(pair));
    _require(
      sync.error == null && cloud.uploads == uploaded,
      'An unchanged album was uploaded again instead of reusing receipts.',
    );
    _require(
      await journal.receipt(pair.id, 'local', [source.name]) != null,
      'The original upload has no persisted receipt.',
    );
    return 'Real PhotoKit original bytes and repeated-upload receipts verified.';
  } finally {
    await sync.disconnect();
    sync.dispose();
    await journal.close();
    await temp.delete(recursive: true);
  }
}
