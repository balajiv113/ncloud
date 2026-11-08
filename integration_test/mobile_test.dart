import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_driver/driver_extension.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/features/library/domain/browse_target.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/storage/file_store.dart';
import 'package:ncloud/features/backup/folder_sync.dart';
import 'package:ncloud/features/backup/ios_album_backup.dart';
import 'package:ncloud/features/library/library_screen.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';
import 'package:ncloud/features/backup/sync_run_lock.dart';
import 'package:ncloud/features/backup/sync_schedule.dart';
import 'package:ncloud/features/backup/workmanager_backup.dart';

import '../test/app_test.dart' show MemoryStore;
import '../test/features/backup/folder_sync_test.dart' show CloudFolders;
import '../test/nextcloud_client_test.dart'
    show account, multistatus, responseEntry;

Future<void> main() async {
  late AppController controller;
  late LocalCache cache;
  late Directory cacheRoot;
  late ValueNotifier<AppController> current;
  var listings = 0;
  final permissionStatus = ValueNotifier<String>('Mobile integration');
  AppController createController() =>
      AppController(
          store: MemoryStore(),
          client: createClient(() => listings++),
          cache: cache,
        )
        ..account = account
        ..target = DriveTarget([]);
  enableFlutterDriverExtension(
    handler: (message) async {
      if (message == 'platform') return Platform.operatingSystem;
      if (message == 'nativeContract') return _testNativeContract();
      if (message == 'reopen') {
        controller.dispose();
        await cache.close();
        cache = LocalCache(() async => cacheRoot);
        controller = createController();
        await controller.load(refresh: false);
        current.value = controller;
        return 'reopened';
      }
      if (message == 'driveState') {
        return jsonEncode({
          'directory': controller.directory.join('/'),
          'items': controller.items.map((f) => f.path.join('/')).toList()
            ..sort(),
          'listings': listings,
          'loading': controller.loading,
          'error': controller.error,
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
        'Unknown mobile test operation',
      );
    },
  );
  WidgetsBinding.instance.ensureSemantics();
  cacheRoot = await Directory.systemTemp.createTemp('ncloud-mobile-');
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
  controller = createController();
  await controller.load();
  current = ValueNotifier(controller);
  runApp(
    MaterialApp(
      home: Scaffold(
        appBar: Platform.isIOS
            ? AppBar(
                title: ValueListenableBuilder<String>(
                  valueListenable: permissionStatus,
                  builder: (_, value, _) => Text(value),
                ),
                actions: [
                  Semantics(
                    identifier: 'ios-photos-permission',
                    child: TextButton(
                      onPressed: () async {
                        permissionStatus.value = 'Requesting Photos access';
                        try {
                          await NativeFolderAccess().albums();
                          permissionStatus.value = 'Photos access ready';
                        } catch (error) {
                          permissionStatus.value =
                              'Photos access failed: $error';
                        }
                      },
                      child: const Text('Choose Photos album'),
                    ),
                  ),
                ],
              )
            : null,
        body: ValueListenableBuilder<AppController>(
          valueListenable: current,
          builder: (_, value, _) => ListenableBuilder(
            listenable: value,
            builder: (_, _) =>
                LibraryScreen(key: ObjectKey(value), controller: value),
          ),
        ),
      ),
    ),
  );
}

NextcloudClient createClient(VoidCallback onListing) {
  const root = '/nextcloud/remote.php/dav/files/alice';
  String folder(String path) => responseEntry(href: '$root/$path/')
      .replaceFirst(
        '<d:resourcetype/>',
        '<d:resourcetype><d:collection/></d:resourcetype>',
      )
      .replaceFirst('image/jpeg', 'httpd/unix-directory')
      .replaceFirst('<oc:fileid>42</oc:fileid>', '<oc:fileid>$path</oc:fileid>')
      .replaceFirst('</d:prop>', '<d:getetag>"folder-v1"</d:getetag></d:prop>');
  return NextcloudClient(
    transport: MockClient((request) async {
      if (request.method != 'PROPFIND') return http.Response('', 404);
      if (request.headers['Depth'] == '1') onListing();
      final nested = request.url.path.endsWith('/Trips');
      final summer = request.url.path.endsWith('/Trips/Summer');
      final empty = request.url.path.endsWith('/Trips/Summer/Autumn');
      return http.Response(
        multistatus(
          empty
              ? folder('Trips/Summer/Autumn')
              : summer
              ? folder('Trips/Summer') +
                    folder('Trips/Summer/Autumn') +
                    responseEntry(
                      href: '$root/Trips/Summer/notes.txt',
                    ).replaceFirst('image/jpeg', 'text/plain')
              : nested
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
}

Future<String> _testNativeContract() async {
  final access = NativeFolderAccess();
  if (Platform.isIOS) {
    _require(
      await NativeFolderAccess.channel.invokeMethod<bool>(
            'albumBackgroundSupported',
          ) !=
          null,
      'iOS did not report background scheduling availability.',
    );
  }
  final conditions = await NativeFolderAccess.channel
      .invokeMapMethod<String, dynamic>('conditions');
  _require(
    conditions?['wifi'] is bool && conditions?['charging'] is bool,
    'Native conditions must return Wi-Fi and charging booleans.',
  );
  final staged = await access.stage();
  try {
    _require(await staged.exists(), 'Native staging file was not created.');
    await staged.writeAsBytes([1, 2, 3]);
  } finally {
    await access.discard(staged);
  }
  _require(!await staged.exists(), 'Native discard left its staging file.');
  final lock = NativeSyncRunLock();
  const owner = 'mobile-contract';
  _require(await lock.acquire(owner), 'Could not acquire native account lock.');
  try {
    _require(
      !await lock.acquire(owner),
      'Native lock allowed duplicate ownership.',
    );
    _require(
      await lock.acquire('$owner-other'),
      'Independent account was blocked.',
    );
    await lock.release('$owner-other');
  } finally {
    await lock.release(owner);
  }
  _require(await lock.acquire(owner), 'Native lock was not released.');
  await lock.release(owner);
  final root = await Directory.systemTemp.createTemp('ncloud-pair-contract-');
  final journal = SyncJournal(path: '${root.path}/pairs.sqlite3');
  final cloud = CloudFolders();
  final sync = FolderSyncController(
    client: cloud,
    account: () => account,
    journal: journal,
  );
  try {
    await sync.load();
    _require(sync.error == null, 'Could not open pair storage: ${sync.error}');
    await sync.add(
      'Saved folder',
      const DeviceFolder('content://fixture/tree/source', 'Source', 'source'),
      ['Backup'],
      wifiOnly: false,
    );
    final saved = sync.pairs.single;
    final worker = SyncJournal(path: journal.path);
    try {
      await worker.writeState(saved.id, {
        'status': 'success',
        'transferred': 1,
      });
    } finally {
      await worker.close();
    }
    await sync.refreshResults();
    _require(
      sync.error == null && sync.results[saved.id]?['status'] == 'success',
      'Worker teardown broke foreground result storage: ${sync.error}',
    );
    await sync.add(
      'Edited folder',
      saved.folder,
      saved.remote,
      wifiOnly: false,
      replacing: saved,
    );
    await journal.close();
    final reopened = await journal.pair(saved.id);
    _require(
      reopened?.folder.token == saved.folder.token &&
          reopened?.name == 'Edited folder' &&
          reopened?.cloudRoot.join('/') == 'Backup/Source',
      'The saved pair did not survive closing and reopening SQLite.',
    );
    await sync.forget(saved);
    _require(
      await journal.pair(saved.id) == null,
      'Pair removal was not saved.',
    );
  } finally {
    await sync.disconnect();
    await journal.close();
    sync.dispose();
    cloud.close();
    await root.delete(recursive: true);
  }
  return 'Native staging, conditions, account locks and pair storage verified.';
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
  final scheduler = IosAlbumScheduler(
    journal: journal,
    readAccount: () async => account,
    initialize: initializeBackupDispatcher,
  );
  final sync = FolderSyncController(
    client: cloud,
    account: () => account,
    access: access,
    journal: journal,
    scheduler: scheduler,
  );
  try {
    await _stage('opening the journal', sync.load);
    await _stage(
      'saving the album pair',
      () => sync.add(
        'Simulator album',
        folder,
        ['Backup'],
        wifiOnly: false,
        schedule: BackupSchedule(created: DateTime.now(), hour: 14),
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
