import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/folder_sync.dart';
import 'package:ncloud/folder_sync_screen.dart';
import 'package:ncloud/app_controller.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';
import 'package:ncloud/photo_backup.dart';
import 'package:ncloud/photo_backup_screen.dart';

import 'nextcloud_client_test.dart' show account;
import 'app_test.dart' show MemoryStore;

class DeviceFolders implements FolderAccess {
  DeviceFolders(this.root, this.staging);
  final Directory root;
  final Directory staging;
  bool denied = false;
  bool wifi = true;
  bool charging = true;
  int imports = 0;
  int exports = 0;
  int count = 0;
  int conditionChecks = 0;
  int picks = 0;
  Object? conditionsError;
  void Function()? beforeImport;

  File file(List<String> path) => File('${root.path}/${path.join('/')}');

  Future<void> put(String path, String content) async {
    final target = file(path.split('/'));
    await target.parent.create(recursive: true);
    await target.writeAsString(content);
    await target.setLastModified(DateTime.utc(2026, 1, 1, 0, 0, count++));
  }

  DeviceEntry entry(FileSystemEntity entity) {
    final stat = entity.statSync();
    return DeviceEntry(
      entity.uri.pathSegments.where((p) => p.isNotEmpty).last,
      stat.type == FileSystemEntityType.directory,
      stat.type == FileSystemEntityType.directory ? 0 : stat.size,
      stat.modified.millisecondsSinceEpoch,
    );
  }

  @override
  Future<DeviceFolder?> pick() async {
    picks++;
    return const DeviceFolder('grant', 'Selected', 'folder-id');
  }

  @override
  Future<List<DeviceEntry>> list(String token, List<String> path) async {
    if (denied) throw const FileSystemException('Permission denied');
    return Directory(
      '${root.path}/${path.join('/')}',
    ).listSync().map(entry).toList();
  }

  @override
  Future<File> export(
    String token,
    List<String> path,
    DeviceEntry expected,
  ) async {
    exports++;
    final source = file(path);
    if (entry(source).version != expected.version) {
      throw const FileSystemException('Source changed');
    }
    return source.copy((await stage()).path);
  }

  @override
  Future<File> stage() async {
    await staging.create(recursive: true);
    return File('${staging.path}/${count++}.part')..createSync();
  }

  @override
  Future<DeviceEntry> import(
    String token,
    List<String> path,
    File staged,
  ) async {
    beforeImport?.call();
    final target = file(path);
    if (await target.exists()) {
      throw const FileSystemException('Already exists');
    }
    await target.parent.create(recursive: true);
    await staged.copy(target.path);
    imports++;
    return entry(target);
  }

  @override
  Future<void> discard(File staged) => staged.delete();

  @override
  Future<SyncConditions> conditions() async {
    conditionChecks++;
    if (conditionsError case final error?) throw error;
    return SyncConditions(wifi: wifi, charging: charging);
  }
}

class PhotoAssets extends DeviceFolders {
  PhotoAssets(super.root, super.staging);
  final originalFolders = <String, List<String>>{};
  bool unknownSize = true;

  @override
  DeviceEntry entry(FileSystemEntity entity) {
    final value = super.entry(entity);
    if (value.directory) return value;
    final asset = entity.parent.uri.pathSegments
        .where((p) => p.isNotEmpty)
        .last;
    return DeviceEntry(
      value.name,
      false,
      unknownSize ? -1 : value.size,
      value.modified,
      backupPath: [...?originalFolders[asset], value.name],
    );
  }

  @override
  Future<File> export(
    String token,
    List<String> path,
    DeviceEntry expected,
  ) async {
    exports++;
    final source = file(path);
    if (super.entry(source).modified != expected.modified) {
      throw const FileSystemException('Source changed');
    }
    return source.copy((await stage()).path);
  }
}

class CloudFolders extends NextcloudClient {
  final files = <String, (List<int>, int)>{};
  final folders = <String>{'', 'Backup'};
  int revision = 0;
  int uploads = 0;
  int downloads = 0;
  bool interrupted = false;
  bool listingFails = false;
  void Function()? beforeUpload;
  Future<void> Function()? holdUpload;

  void put(String path, String content) {
    files[path] = (utf8.encode(content), ++revision);
    final parts = path.split('/');
    for (var i = 1; i < parts.length; i++) {
      folders.add(parts.take(i).join('/'));
    }
  }

  CloudFile cloud(String path) {
    final value = files[path]!;
    return CloudFile(
      path: path.split('/'),
      name: path.split('/').last,
      isDirectory: false,
      size: value.$1.length,
      etag: '"${value.$2}"',
    );
  }

  @override
  Future<List<CloudFile>> listFiles(Account account, List<String> path) async {
    if (listingFails) throw const CloudException('Listing failed');
    final prefix = path.isEmpty ? '' : '${path.join('/')}/';
    if (!folders.contains(path.join('/'))) {
      throw const CloudException('Folder missing');
    }
    return [
      for (final folder in folders)
        if (folder.startsWith(prefix) &&
            folder != path.join('/') &&
            !folder.substring(prefix.length).contains('/'))
          CloudFile(
            path: folder.split('/'),
            name: folder.split('/').last,
            isDirectory: true,
          ),
      for (final name in files.keys)
        if (name.startsWith(prefix) &&
            !name.substring(prefix.length).contains('/'))
          cloud(name),
    ];
  }

  @override
  Future<void> createFolder(Account account, List<String> path) async {
    if (!folders.add(path.join('/'))) {
      throw const CloudException('Folder exists');
    }
  }

  @override
  Future<void> upload(
    Account account,
    List<String> path,
    Stream<List<int>> bytes,
    int size,
  ) async {
    await holdUpload?.call();
    beforeUpload?.call();
    final name = path.join('/');
    if (files.containsKey(name)) throw const CloudException('Already exists');
    final content = await bytes.expand((chunk) => chunk).toList();
    if (interrupted) throw const CloudException('Transfer interrupted');
    files[name] = (content, ++revision);
    uploads++;
  }

  @override
  Future<http.StreamedResponse> downloadVersion(
    Account account,
    CloudFile file,
  ) async {
    final value = files[file.path.join('/')]!;
    if (file.etag != '"${value.$2}"') {
      throw const CloudException('Revision changed');
    }
    downloads++;
    return http.StreamedResponse(
      interrupted
          ? Stream.error(const SocketException('Interrupted'))
          : Stream.value(value.$1),
      200,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late DeviceFolders device;
  late CloudFolders cloud;
  late FolderSyncController sync;
  late Account? session;
  late String journalPath;
  bool disposed = false;

  FolderSyncController controller({bool android = true}) =>
      FolderSyncController(
        client: cloud,
        account: () => session,
        access: device,
        journal: SyncJournal(path: journalPath),
        android: android,
      );

  Future<FolderPair> pair(
    SyncMode mode, {
    bool repeat = false,
    bool chargingOnly = false,
  }) async {
    await sync.load();
    await sync.add(
      'My backup',
      const DeviceFolder('grant', 'Selected', 'folder-id'),
      ['Backup'],
      mode,
      repeat,
      chargingOnly: chargingOnly,
    );
    return sync.pairs.single;
  }

  setUp(() async {
    disposed = false;
    final parent = await Directory(
      '.dart_tool/folder-sync-tests',
    ).absolute.create(recursive: true);
    root = await parent.createTemp('run-');
    final source = await Directory('${root.path}/device').create();
    device = DeviceFolders(source, Directory('${root.path}/staging'));
    cloud = CloudFolders();
    session = account;
    journalPath = '${root.path}/sync.sqlite3';
    sync = controller();
  });

  tearDown(() async {
    await sync.disconnect();
    await sync.journal.close();
    if (!disposed) sync.dispose();
    cloud.close();
    await root.delete(recursive: true);
  });

  for (final android in [false, true]) {
    test(
      '${android ? 'Android folders' : 'iPhone flat'} photo backup preserves originals and remembers assets',
      () async {
        await sync.disconnect();
        await sync.journal.close();
        sync.dispose();
        sync = controller(android: android);
        final photos = PhotoAssets(device.root, device.staging)
          ..originalFolders['asset-a'] = ['DCIM', 'Camera']
          ..originalFolders['asset-b'] = ['Pictures', 'Trips']
          ..unknownSize = !android;
        await photos.put('asset-a/IMG_0001.HEIC', 'original-a');
        await photos.put('asset-a/IMG_0001.MOV', 'live-motion');
        await photos.put('asset-b/IMG_0001.HEIC', 'original-b');
        cloud.folders.add('Chosen');
        final protectedPath = android
            ? 'Chosen/DCIM/Camera/IMG_0001.HEIC'
            : 'Chosen/IMG_0001.HEIC';
        cloud.put(protectedPath, 'existing-cloud-original');
        await sync.enablePhotos(
          photos,
          wifiOnly: true,
          destination: ['Chosen'],
        );
        final configured = sync.pairs.single;
        expect(FolderPair.fromJson(configured.toJson()).photoBackup, isTrue);
        await sync.run(configured);
        expect(sync.error, isNull);
        expect(sync.transferred, 3);
        expect(
          utf8.decode(cloud.files[protectedPath]!.$1),
          'existing-cloud-original',
        );
        expect(
          cloud.files.values.map((f) => utf8.decode(f.$1)),
          containsAll(['original-a', 'original-b', 'live-motion']),
        );
        expect(
          cloud.files.keys,
          everyElement(
            android
                ? startsWith('Chosen/')
                : matches(RegExp(r'^Chosen/[^/]+$')),
          ),
        );
        if (android) {
          expect(
            cloud.files.keys,
            contains('Chosen/Pictures/Trips/IMG_0001.HEIC'),
          );
        }
        expect(photos.imports, 0);
        expect(device.picks, 0);
        expect(
          await photos.file(['asset-a', 'IMG_0001.HEIC']).readAsString(),
          'original-a',
        );
        expect(photos.staging.listSync(), isEmpty);
        await sync.disconnect();
        await sync.journal.close();
        sync.dispose();
        sync = controller(android: android)..photoAccess = photos;
        await sync.load();
        expect(sync.pairs, hasLength(1));
        await sync.run(sync.pairs.single);
        expect(sync.error, isNull);
        expect(sync.transferred, 0);
        expect(cloud.uploads, 3);
        await photos.file(['asset-a', 'IMG_0001.HEIC']).delete();
        await sync.run(sync.pairs.single);
        expect(cloud.files, hasLength(4));
        expect(cloud.uploads, 3);
      },
    );
  }

  test(
    'changing photo destination replaces settings atomically, not cloud files',
    () async {
      sync = sync..photoAccess = device;
      cloud.folders.addAll(['One', 'Two']);
      await sync.enablePhotos(device, wifiOnly: true, destination: ['One']);
      final original = sync.pairs.single;
      original.lastRun = DateTime.now();
      cloud.put('One/kept.jpg', 'keep');
      await sync.enablePhotos(device, wifiOnly: false, destination: ['One']);
      expect(sync.pairs.single.id, original.id);
      expect(sync.pairs.single.lastRun, isNotNull);
      await sync.enablePhotos(device, wifiOnly: true, destination: ['Two']);
      expect(sync.pairs.single.id, isNot(original.id));
      expect(sync.pairs.single.lastRun, isNull);
      expect((await sync.journal.pairs(syncAccount(account))).single.remote, [
        'Two',
      ]);
      expect(cloud.files.keys, ['One/kept.jpg']);
    },
  );

  test(
    'photo destinations cannot overlap custom pairs in either direction',
    () async {
      await pair(SyncMode.backup);
      for (final path in [
        <String>[],
        ['Backup'],
        ['Backup', 'Nested'],
      ]) {
        await expectLater(
          sync.enablePhotos(device, wifiOnly: true, destination: path),
          throwsFormatException,
        );
      }
      await sync.enablePhotos(
        device,
        wifiOnly: true,
        destination: ['Separate'],
      );
      await expectLater(
        sync.add(
          'No overlap',
          const DeviceFolder('other', 'Other', 'other'),
          ['Separate', 'Nested'],
          SyncMode.backup,
          false,
        ),
        throwsFormatException,
      );
      expect(cloud.uploads, 0);
    },
  );

  test(
    'photo permission status never prompts except on explicit request',
    () async {
      final calls = <MethodCall>[];
      final photos = PhotoLibraryAccess();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PhotoLibraryAccess.channel, (call) async {
            calls.add(call);
            if (call.method == 'photos.permission') return 'limited';
            if (call.method == 'photos.scan') {
              return [
                {'id': 'asset-id', 'modified': 12},
              ];
            }
            if (call.method == 'photos.resources') {
              return [
                {'name': 'original.HEIC', 'size': -1, 'modified': 12},
              ];
            }
            throw StateError('Unexpected ${call.method}');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PhotoLibraryAccess.channel, null),
      );
      expect(await photos.permission(), 'limited');
      expect(await photos.permission(request: true), 'limited');
      expect((await photos.list('photos', [])).single.name, 'asset-id');
      expect((await photos.list('photos', ['asset-id'])).single.size, -1);
      expect(calls.map((c) => c.method), [
        'photos.permission',
        'photos.permission',
        'photos.scan',
        'photos.resources',
      ]);
      expect((calls.first.arguments as Map)['request'], false);
      expect((calls[1].arguments as Map)['request'], true);
      expect(
        () => photos.import('photos', ['file'], File('not-used')),
        throwsUnsupportedError,
      );
    },
  );

  test(
    'photo scan rejects duplicate asset identifiers and invalid native status',
    () async {
      final photos = PhotoLibraryAccess();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PhotoLibraryAccess.channel, (call) async {
            if (call.method == 'photos.permission') return null;
            return [
              {'id': 'same', 'modified': 12},
              {'id': 'same', 'modified': 12},
            ];
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PhotoLibraryAccess.channel, null),
      );
      await expectLater(photos.permission(), throwsStateError);
      await expectLater(photos.list('photos', []), throwsFormatException);
    },
  );

  testWidgets(
    'photo setup shows saved destination and limited access without prompting',
    (tester) async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(PhotoLibraryAccess.channel, (call) async {
            calls.add(call);
            if (call.method == 'photos.permission') return 'limited';
            throw StateError('Unexpected ${call.method}');
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(PhotoLibraryAccess.channel, null),
      );
      final controller = AppController(
        store: MemoryStore(),
        folderSyncController: sync,
      )..account = account;
      await tester.runAsync(
        () =>
            sync.enablePhotos(device, wifiOnly: true, destination: ['Backup']),
      );
      await tester.binding.setSurfaceSize(const Size(450, 1800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(home: PhotoBackupScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.text('Photos access: Limited'), findsOneWidget);
      expect(find.text('/Backup'), findsOneWidget);
      expect(find.textContaining('Only approved items'), findsOneWidget);
      expect(find.text('Open device permission settings'), findsOneWidget);
      expect(calls.map((c) => c.method), ['photos.permission']);
      expect((calls.single.arguments as Map)['request'], false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(sync.disconnect);
      await tester.runAsync(sync.journal.close);
      controller.dispose();
      disposed = true;
    },
  );

  test('selected source folder is included even when empty', () async {
    final value = await pair(SyncMode.backup);
    expect(value.cloudRoot, ['Backup', 'Selected']);
    await sync.run(value);
    expect(sync.error, isNull);
    expect(cloud.folders, contains('Backup/Selected'));
    expect(cloud.uploads, 0);
    expect(cloud.files, isEmpty);
    expect(FolderPair.fromJson(value.toJson()).cloudRoot, value.cloudRoot);
  });

  test(
    'previously flattened files stay untouched when backup includes the source folder',
    () async {
      await device.put('nested/file.txt', 'original');
      final value = await pair(SyncMode.backup);
      cloud.put('Backup/nested/file.txt', 'original');
      final oldVersion = '${cloud.cloud('Backup/nested/file.txt').etag}|8';
      await sync.journal.confirm(
        value.id,
        ['nested', 'file.txt'],
        device.entry(device.file(['nested', 'file.txt'])).version,
        ['nested', 'file.txt'],
        oldVersion,
      );
      await sync.run(value);
      expect(sync.error, isNull);
      expect(
        cloud.files.keys,
        containsAll([
          'Backup/nested/file.txt',
          'Backup/Selected/nested/file.txt',
        ]),
      );
      expect(
        cloud.files.values.map((f) => utf8.decode(f.$1)),
        everyElement('original'),
      );
      expect(cloud.uploads, 1);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
      expect(device.imports, 0);
    },
  );

  test(
    'a file blocking the source folder name stops without changing it',
    () async {
      await device.put('notes.txt', 'local');
      cloud.put('Backup/Selected', 'protected');
      final value = await pair(SyncMode.backup);
      await sync.run(value);
      expect(sync.error, contains('file blocks'));
      expect(utf8.decode(cloud.files['Backup/Selected']!.$1), 'protected');
      expect(cloud.uploads, 0);
      expect(device.imports, 0);
      expect(cloud.folders, isNot(contains('Backup/Selected')));
    },
  );

  test('invalid source folder names cannot create a cloud path', () async {
    await sync.load();
    await expectLater(
      sync.add(
        'Unsafe',
        const DeviceFolder('grant', '../Documents', 'folder-id'),
        ['Backup'],
        SyncMode.backup,
        false,
      ),
      throwsFormatException,
    );
    expect(sync.pairs, isEmpty);
    expect(cloud.folders, {'', 'Backup'});
  });

  test('backup preserves server names, local deletions and restarts', () async {
    await device.put('nested/photo.jpg', 'local photo');
    cloud.put('Backup/Selected/nested/photo.jpg', 'existing cloud photo');
    final value = await pair(SyncMode.backup);
    await sync.run(value);
    expect(sync.error, isNull);
    expect(cloud.uploads, 1);
    expect(
      utf8.decode(cloud.files['Backup/Selected/nested/photo.jpg']!.$1),
      'existing cloud photo',
    );
    expect(cloud.files, hasLength(2));
    await sync.run(value);
    expect(cloud.uploads, 1);
    final checks = device.conditionChecks;
    await sync.run(value);
    expect(
      device.conditionChecks,
      checks + 1,
      reason:
          'Unchanged files must not repeatedly wake native network monitors.',
    );
    await sync.disconnect();
    await sync.journal.close();
    sync.dispose();
    sync = controller();
    await sync.load();
    await sync.run(sync.pairs.single);
    expect(cloud.uploads, 1);
    await device.file(['nested', 'photo.jpg']).delete();
    await sync.run(sync.pairs.single);
    expect(cloud.files, hasLength(2));
  });

  test(
    'download preserves local files and cloud deletions do not delete locally',
    () async {
      await device.put('photo.jpg', 'existing local');
      cloud.put('Backup/photo.jpg', 'remote original');
      final value = await pair(SyncMode.download);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(await device.file(['photo.jpg']).readAsString(), 'existing local');
      expect(device.imports, 1);
      expect(cloud.uploads, 0);
      await sync.run(value);
      expect(device.imports, 1);
      cloud.files.clear();
      await sync.run(value);
      expect(device.root.listSync().whereType<File>(), hasLength(2));
    },
  );

  test(
    'two-way merge reaches a fixed point and edited versions keep originals',
    () async {
      await device.put('same.txt', 'local version');
      await device.put('only-local.txt', 'local');
      cloud.put('Backup/Selected/same.txt', 'cloud version');
      cloud.put('Backup/Selected/only-remote.txt', 'remote');
      final value = await pair(SyncMode.merge);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 2);
      expect(device.imports, 2);
      expect(await device.file(['same.txt']).readAsString(), 'local version');
      expect(
        utf8.decode(cloud.files['Backup/Selected/same.txt']!.$1),
        'cloud version',
      );
      await sync.run(value);
      expect(cloud.uploads, 2);
      expect(device.imports, 2);
      await device.put('only-local.txt', 'new local version');
      await sync.run(value);
      expect(sync.error, isNull);
      expect(
        utf8.decode(cloud.files['Backup/Selected/only-local.txt']!.$1),
        'local',
      );
      final uploads = cloud.uploads;
      final downloads = device.imports;
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, uploads);
      expect(device.imports, downloads);
    },
  );

  test(
    'permission errors stop the entire scan without interpreting deletions',
    () async {
      await device.put('keep.txt', 'local');
      cloud.put('Backup/Selected/keep.txt', 'remote');
      final value = await pair(SyncMode.merge);
      device.denied = true;
      await sync.run(value);
      expect(sync.error, isNotNull);
      expect(cloud.uploads, 0);
      expect(device.imports, 0);
      expect(cloud.files, hasLength(1));
      expect(await device.file(['keep.txt']).readAsString(), 'local');
      device.denied = false;
    },
  );

  test('failed remote scan never starts transfers', () async {
    await device.put('keep.txt', 'local');
    final value = await pair(SyncMode.merge);
    cloud.listingFails = true;
    await sync.run(value);
    expect(sync.error, 'Listing failed');
    expect(cloud.uploads, 0);
    expect(device.imports, 0);
  });

  test(
    'interrupted file has no success receipt and temporary bytes are removed',
    () async {
      await device.put('file.txt', 'source bytes');
      final value = await pair(SyncMode.backup);
      cloud.interrupted = true;
      await sync.run(value);
      expect(sync.error, isNotNull);
      expect(
        await sync.journal.receipt(value.id, 'local', ['file.txt']),
        isNull,
      );
      expect(device.staging.listSync(), isEmpty);
      cloud.interrupted = false;
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
    },
  );

  test('interrupted download never imports partial files', () async {
    cloud.put('Backup/file.txt', 'source bytes');
    final value = await pair(SyncMode.download);
    cloud.interrupted = true;
    await sync.run(value);
    expect(sync.error, isNotNull);
    expect(device.imports, 0);
    expect(device.root.listSync(), isEmpty);
    expect(device.staging.listSync(), isEmpty);
    cloud.interrupted = false;
    await sync.run(value);
    expect(sync.error, isNull);
    expect(device.imports, 1);
  });

  test('destination races never overwrite cloud files', () async {
    await device.put('file.txt', 'source');
    final value = await pair(SyncMode.backup);
    cloud.beforeUpload = () =>
        cloud.put('Backup/Selected/file.txt', 'racing content');
    await sync.run(value);
    expect(sync.error, isNotNull);
    expect(
      utf8.decode(cloud.files['Backup/Selected/file.txt']!.$1),
      'racing content',
    );
    expect(await sync.journal.receipt(value.id, 'local', ['file.txt']), isNull);
  });

  test('destination races never overwrite device files', () async {
    cloud.put('Backup/file.txt', 'source');
    final value = await pair(SyncMode.download);
    device.beforeImport = () =>
        device.file(['file.txt']).writeAsStringSync('racing content');
    await sync.run(value);
    expect(sync.error, isNotNull);
    expect(await device.file(['file.txt']).readAsString(), 'racing content');
    expect(
      await sync.journal.receipt(value.id, 'remote', ['file.txt']),
      isNull,
    );
  });

  test(
    'Wi-Fi and charging policies block work without losing pending files',
    () async {
      await device.put('file.txt', 'source');
      final value = await pair(SyncMode.backup, chargingOnly: true);
      device.wifi = false;
      await sync.run(value);
      expect(sync.error, contains('Wi-Fi'));
      expect(cloud.uploads, 0);
      device.wifi = true;
      device.charging = false;
      await sync.run(value);
      expect(sync.error, contains('charging'));
      device.charging = true;
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
    },
  );

  test(
    'missing native policy handler does not request or blame folder permission',
    () async {
      await device.put('file.txt', 'source');
      final value = await pair(SyncMode.backup);
      device.conditionsError = MissingPluginException('conditions');
      await sync.run(value);
      expect(sync.error, contains('native folder-sync service'));
      expect(sync.error, contains('Reconnecting the folder will not fix this'));
      expect(device.picks, 0);
      expect(cloud.uploads, 0);
      device.conditionsError = null;
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
      expect(device.picks, 0);
    },
  );

  test(
    'native bridge reuses the saved grant on repeated sync without opening picker',
    () async {
      await device.put('file.txt', 'source');
      final calls = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        calls.add(call.method);
        final args = (call.arguments as Map?)?.cast<String, dynamic>();
        switch (call.method) {
          case 'conditions':
            return {'wifi': true, 'charging': true};
          case 'list':
            expect(args!['token'], 'grant');
            return [
              for (final entry in await device.list(
                'grant',
                (args['path'] as List).cast<String>(),
              ))
                {
                  'name': entry.name,
                  'directory': entry.directory,
                  'size': entry.size,
                  'modified': entry.modified,
                },
            ];
          case 'export':
            expect(args!['token'], 'grant');
            return (await device.export(
              'grant',
              (args['path'] as List).cast<String>(),
              DeviceEntry(
                'file.txt',
                false,
                args['size'] as int,
                args['modified'] as int,
              ),
            )).path;
          case 'discard':
            await device.discard(File(args!['staged'] as String));
            return null;
          default:
            fail('Unexpected native call: ${call.method}');
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          NativeFolderAccess.channel,
          null,
        ),
      );
      sync.dispose();
      sync = FolderSyncController(
        client: cloud,
        account: () => session,
        access: NativeFolderAccess(),
        journal: SyncJournal(path: journalPath),
        android: true,
      );
      final value = await pair(SyncMode.backup);
      await sync.run(value);
      expect(sync.error, isNull);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
      expect(calls.where((method) => method == 'conditions'), hasLength(3));
      expect(calls, isNot(contains('pick')));
      expect(device.picks, 0);
    },
  );

  test(
    'backgrounding pauses between files, then manual run skips completed work',
    () async {
      await device.put('one.txt', 'one');
      await device.put('two.txt', 'two');
      final value = await pair(SyncMode.backup);
      cloud.beforeUpload = () => sync.setForeground(false);
      await sync.run(value);
      expect(cloud.uploads, 1);
      expect(sync.phase, contains('Paused'));
      cloud.beforeUpload = null;
      sync.setForeground(true);
      await sync.run(value);
      expect(cloud.uploads, 2);
      expect(sync.error, isNull);
    },
  );

  test(
    'account changes cannot run another account pair or display its pairs',
    () async {
      await device.put('file.txt', 'source');
      final value = await pair(SyncMode.backup);
      session = Account(
        server: Uri(scheme: 'https', host: 'different.example'),
        loginName: 'other',
        appPassword: 'test',
        userId: 'other',
        displayName: 'Other',
      );
      await sync.run(value);
      expect(cloud.uploads, 0);
      await sync.load();
      expect(sync.pairs, isEmpty);
    },
  );

  test(
    'iPhone saved pairs can run repeatedly but never schedule repeat',
    () async {
      sync.dispose();
      sync = controller(android: false);
      final value = await pair(SyncMode.backup, repeat: true);
      expect(value.repeat, isFalse);
      await device.put('first.txt', 'one');
      await sync.run(value);
      await device.put('second.txt', 'two');
      await sync.run(value);
      expect(cloud.uploads, 2);
      expect(sync.error, isNull);
    },
  );

  test('forgetting pairs removes only settings and history', () async {
    await device.put('file.txt', 'source');
    final value = await pair(SyncMode.merge);
    await sync.run(value);
    await sync.forget(value);
    expect(sync.pairs, isEmpty);
    expect(await sync.journal.pairs(syncAccount(account)), isEmpty);
    expect(await device.file(['file.txt']).readAsString(), 'source');
    expect(cloud.files, hasLength(1));
  });

  test(
    'overlapping cloud destinations and device grants are rejected',
    () async {
      await pair(SyncMode.backup);
      await expectLater(
        sync.add(
          'Nested',
          const DeviceFolder('different', 'other', 'other'),
          ['Backup', 'Child'],
          SyncMode.backup,
          false,
        ),
        throwsFormatException,
      );
      await expectLater(
        sync.add(
          'Same grant',
          const DeviceFolder('grant', 'Selected', 'folder-id'),
          ['Other'],
          SyncMode.backup,
          false,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'relative paths reject traversal, separators and control characters',
    () {
      for (final name in ['..', '.', '', 'a/b', r'a\b', 'a\u0000b']) {
        expect(() => checkSyncPath(['folder', name]), throwsFormatException);
      }
      expect(
        () => checkSyncPath(['folder', 'photo & video.jpg']),
        returnsNormally,
      );
    },
  );

  test(
    'sync transport enforces revision and create-only HTTP conditions',
    () async {
      final methods = <String>[];
      final client = NextcloudClient(
        transport: MockClient((request) async {
          methods.add(request.method);
          expect(request.followRedirects, isFalse);
          if (request.method == 'GET') {
            expect(request.headers['If-Match'], '"revision"');
            return http.Response('source', 412);
          }
          expect(request.method, 'PUT');
          expect(request.headers['If-None-Match'], '*');
          return http.Response('', 412);
        }),
      );
      addTearDown(client.close);
      final file = CloudFile(
        path: const ['Backup', 'file.txt'],
        name: 'file.txt',
        isDirectory: false,
        etag: 'revision',
      );
      await expectLater(
        client.downloadVersion(account, file),
        throwsA(isA<CloudException>()),
      );
      await expectLater(
        client.upload(
          account,
          file.path,
          Stream.value(utf8.encode('source')),
          6,
        ),
        throwsA(isA<CloudException>()),
      );
      expect(methods, ['GET', 'PUT']);
    },
  );

  testWidgets('dashboard and setup expose safe modes and explicit consent', (
    tester,
  ) async {
    final controller = AppController(
      store: MemoryStore(),
      folderSyncController: sync,
    )..account = account;
    await tester.runAsync(sync.load);
    await tester.pumpWidget(
      MaterialApp(home: FolderSyncScreen(controller: controller)),
    );
    await tester.runAsync(sync.load);
    await tester.pumpAndSettle();
    expect(find.text('Your files stay protected'), findsOneWidget);
    expect(find.text('Add sync pair'), findsOneWidget);
    await tester.ensureVisible(find.text('Add sync pair'));
    await tester.tap(find.text('Add sync pair'));
    await tester.pumpAndSettle();
    expect(find.text('Transfer direction'), findsOneWidget);
    expect(find.text('Wi-Fi only'), findsOneWidget);
    expect(find.text('Only while charging'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<SyncMode>));
    await tester.pumpAndSettle();
    expect(find.text(SyncMode.download.label).last, findsOneWidget);
    expect(find.text(SyncMode.merge.label).last, findsOneWidget);
    await tester.tap(find.text(SyncMode.backup.label).last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Save pair'),
      200,
      scrollable: find
          .byWidgetPredicate(
            (widget) =>
                widget is Scrollable &&
                widget.axisDirection == AxisDirection.down,
          )
          .last,
    );
    final save = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Save pair'),
    );
    expect(save.onPressed, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    // The test fixture owns sync's asynchronous shutdown.
    controller.dispose();
    disposed = true;
  });
}
