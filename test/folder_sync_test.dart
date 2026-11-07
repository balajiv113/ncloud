import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/folder_sync.dart';
import 'package:ncloud/models.dart';
import 'package:ncloud/nextcloud_client.dart';
import 'package:ncloud/cloud_backend.dart';
import 'package:ncloud/sync_rules.dart';
import 'package:ncloud/sync_background.dart';

import 'nextcloud_client_test.dart' show account;

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

class TestSyncBackground implements SyncBackground {
  int starts = 0, stops = 0;
  bool allowed = false;
  Object? startError;
  void Function(String?)? onPause;
  @override
  Future<bool> permission({bool request = false}) async => request || allowed;
  @override
  Future<void> start(void Function(String?) callback) async {
    if (startError case final e?) throw e;
    starts++;
    onPause = callback;
  }

  @override
  Future<void> stop() async {
    stops++;
    onPause = null;
  }
}

class CloudFolders implements CloudBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected backend call: ${invocation.memberName}',
  );

  @override
  void close() {}

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
  Future<CloudDownload> downloadVersion(Account account, CloudFile file) async {
    final value = files[file.path.join('/')]!;
    if (file.etag != '"${value.$2}"') {
      throw const CloudException('Revision changed');
    }
    downloads++;
    return CloudDownload(
      interrupted
          ? Stream.error(const SocketException('Interrupted'))
          : Stream.value(value.$1),
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
  late TestSyncBackground background;

  FolderSyncController controller({bool android = true}) =>
      FolderSyncController(
        client: cloud,
        account: () => session,
        access: device,
        journal: SyncJournal(path: journalPath),
        android: android,
        backgroundService: background,
      );

  Future<FolderPair> pair({
    SyncRules rules = const SyncRules.all(),
    int concurrency = 1,
    bool inBackground = false,
  }) async {
    await sync.load();
    await sync.add(
      'My backup',
      const DeviceFolder('grant', 'Selected', 'folder-id'),
      ['Backup'],
      rules: rules,
      uploadConcurrency: concurrency,
    );
    background.allowed = inBackground;
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
    background = TestSyncBackground();
    sync = controller();
  });

  tearDown(() async {
    await sync.disconnect();
    await sync.journal.close();
    if (!disposed) sync.dispose();
    cloud.close();
    await root.delete(recursive: true);
  });

  test(
    'loading starts empty and removes obsolete photo settings only',
    () async {
      await sync.load();
      expect(sync.pairs, isEmpty);
      final custom = await pair();
      final payload = custom.toJson()
        ..['id'] = 'obsolete-photos'
        ..['photoBackup'] = true;
      await (await sync.journal.db).insert('pairs', {
        'id': 'obsolete-photos',
        'account': syncAccount(account),
        'payload': jsonEncode(payload),
      });
      cloud.put('Photos/kept.jpg', 'original');
      final saved = await sync.journal.pairs(syncAccount(account));
      expect(saved.map((p) => p.id), [custom.id]);
      expect((await (await sync.journal.db).query('pairs')).length, 1);
      expect(cloud.files.keys, ['Photos/kept.jpg']);
      expect(device.picks, 0);
      expect(device.exports, 0);
    },
  );

  test(
    'rules include selected subfolders, subtract exclusions and filter file types',
    () async {
      await device.put('Trips/keep.JPG', 'photo');
      await device.put('Trips/clip.MOV', 'video');
      await device.put('Trips/document.pdf', 'document');
      await device.put('Trips/Private/no.jpg', 'private');
      await device.put('TripsExtra/no.jpg', 'not included');
      final rules = SyncRules.patterns(
        'Trips/**/*.jpg, Trips/**/*.mov',
        'Trips/Private/**',
      );
      final value = await pair(rules: rules, concurrency: 3);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.files.keys.toSet(), {
        'Backup/Selected/Trips/keep.JPG',
        'Backup/Selected/Trips/clip.MOV',
      });
      expect(device.exports, 2);
      expect(rules.visits(['Trips']), isTrue);
      expect(rules.visits(['Trips', 'Private']), isFalse);
      expect(rules.visits(['TripsExtra']), isTrue);
      expect(rules.allows(['Trips', 'Private', 'no.jpg']), isFalse);
      expect(
        rules.allows([
          'Trips',
          'keep.JPG',
        ], contentType: 'application/octet-stream'),
        isTrue,
      );
      final json = value.toJson();
      final restored = FolderPair.fromJson(json);
      expect(restored.rules.toJson(), rules.toJson());
      expect(restored.uploadConcurrency, 3);
    },
  );

  test(
    'changing rules retains confirmed receipts and never removes excluded backups',
    () async {
      await device.put('Public/keep.jpg', 'keep');
      await device.put('Private/old.jpg', 'private');
      final value = await pair();
      await sync.run(value);
      expect(cloud.uploads, 2);
      await device.put('Private/new.jpg', 'do not upload');
      await sync.add(
        value.name,
        value.folder,
        value.remote,
        replacing: value,
        rules: SyncRules.patterns('', 'Private/**'),
      );
      final edited = sync.pairs.single;
      expect(edited.id, value.id);
      await sync.run(edited);
      expect(sync.error, isNull);
      expect(cloud.uploads, 2);
      expect(cloud.files.keys, contains('Backup/Selected/Private/old.jpg'));
      expect(
        cloud.files.keys,
        isNot(contains('Backup/Selected/Private/new.jpg')),
      );
      await sync.disconnect();
      await sync.journal.close();
      sync.dispose();
      sync = controller();
      await sync.load();
      expect(sync.pairs.single.rules.exclude, ['Private/**']);
      await sync.run(sync.pairs.single);
      expect(cloud.uploads, 2);
    },
  );

  test(
    'manually selected media folder applies inclusion and exclusion rules',
    () async {
      await device.put('Camera/yes.HEIC', 'yes');
      await device.put('Screenshots/no.png', 'no');
      await device.put('Camera/no.MOV', 'video excluded');
      await sync.load();
      await sync.add(
        'Selected',
        const DeviceFolder('token', 'Selected', 'identity'),
        ['Backup'],
        rules: SyncRules.patterns('*.heic, *.png', 'Screenshots/**'),
        uploadConcurrency: 3,
      );
      await sync.run(sync.pairs.single);
      expect(sync.error, isNull);
      expect(cloud.files.keys, ['Backup/Selected/Camera/yes.HEIC']);
      expect(device.exports, 1);
      expect(device.imports, 0);
    },
  );

  test(
    'parallel uploads are bounded to three and do not race folder creation',
    () async {
      for (var i = 0; i < 7; i++) {
        await device.put('nested/$i.jpg', 'image-$i');
      }
      var active = 0, maximum = 0;
      final release = Completer<void>();
      cloud.holdUpload = () async {
        active++;
        if (active > maximum) maximum = active;
        if (active == 3 && !release.isCompleted) release.complete();
        await release.future;
        await Future<void>.delayed(const Duration(milliseconds: 2));
        active--;
      };
      final value = await pair(concurrency: 3);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(maximum, 3);
      expect(cloud.uploads, 7);
      expect(cloud.folders, contains('Backup/Selected/nested'));
      expect(device.staging.listSync(), isEmpty);
      await sync.run(value);
      expect(cloud.uploads, 7);
    },
  );

  test(
    'parallel failure settles started uploads and cleans every staged file',
    () async {
      for (var i = 0; i < 6; i++) {
        await device.put('$i.jpg', 'image-$i');
      }
      var started = 0;
      final allStarted = Completer<void>();
      cloud.holdUpload = () async {
        final n = ++started;
        if (started == 3) allStarted.complete();
        await allStarted.future;
        if (n == 1) throw const CloudException('First upload failed');
      };
      final value = await pair(concurrency: 3, inBackground: true);
      await sync.run(value);
      expect(sync.error, 'First upload failed');
      expect(started, 3);
      expect(cloud.uploads, 2);
      expect(sync.transferred, 2);
      expect(sync.activeId, isNull);
      expect(device.staging.listSync(), isEmpty);
      expect(background.stops, 1);
      cloud.holdUpload = null;
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 6);
    },
  );

  test(
    'parallel filename collisions keep all originals and wait for failures',
    () async {
      for (final id in ['a', 'b', 'c']) {
        await device.put('$id/same.jpg', id);
        cloud.put('Backup/Selected/$id/same.jpg', 'existing-$id');
      }
      await pair(concurrency: 3);
      await sync.run(sync.pairs.single);
      expect(sync.error, isNull);
      expect(cloud.files, hasLength(6));
      expect(cloud.files.values.map((f) => utf8.decode(f.$1)).toSet(), {
        'existing-a',
        'existing-b',
        'existing-c',
        'a',
        'b',
        'c',
      });
      await sync.run(sync.pairs.single);
      expect(cloud.uploads, 3);
    },
  );

  test(
    'background-enabled run continues across lifecycle changes and stops its service',
    () async {
      await device.put('first.txt', 'one');
      await device.put('second.txt', 'two');
      final started = Completer<void>(), release = Completer<void>();
      cloud.holdUpload = () async {
        if (!started.isCompleted) started.complete();
        await release.future;
      };
      final value = await pair(inBackground: true);
      final running = sync.run(value);
      await started.future;
      expect(background.starts, 1);
      sync.setForeground(false);
      release.complete();
      await running;
      expect(sync.error, isNull);
      expect(cloud.uploads, 2);
      expect(background.stops, 1);
      expect(sync.activeId, isNull);
    },
  );

  test(
    'notification pause stops subsequent files, preserving completed receipts',
    () async {
      await device.put('first.txt', 'one');
      await device.put('second.txt', 'two');
      cloud.beforeUpload = () => background.onPause?.call(null);
      final value = await pair(inBackground: true);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(sync.phase, contains('Paused'));
      expect(cloud.uploads, 1);
      expect(background.stops, 1);
      cloud.beforeUpload = null;
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 2);
    },
  );

  test(
    'background startup failure performs no transfers or permission prompts',
    () async {
      await device.put('first.txt', 'one');
      background.startError = PlatformException(code: 'background_permission');
      final value = await pair(inBackground: true);
      await sync.run(value);
      expect(sync.error, contains('notifications'));
      expect(cloud.uploads, 0);
      expect(device.exports, 0);
      expect(background.stops, 0);
      expect(sync.activeId, isNull);
    },
  );

  test(
    'persisted pairs require the current schema and reject invalid concurrency',
    () async {
      final value = await pair();
      for (final field in ['rules', 'uploadConcurrency', 'wifiOnly']) {
        expect(
          () => FolderPair.fromJson(value.toJson()..remove(field)),
          throwsA(isA<TypeError>()),
          reason: field,
        );
      }
      for (final count in [0, 4]) {
        await expectLater(
          sync.add('Bad', value.folder, [
            'Elsewhere',
          ], uploadConcurrency: count),
          throwsFormatException,
        );
      }
    },
  );

  test('selected source folder is included even when empty', () async {
    final value = await pair();
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
      final value = await pair();
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
      final value = await pair();
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
      ),
      throwsFormatException,
    );
    expect(sync.pairs, isEmpty);
    expect(cloud.folders, {'', 'Backup'});
  });

  test('backup preserves server names, local deletions and restarts', () async {
    await device.put('nested/photo.jpg', 'local photo');
    cloud.put('Backup/Selected/nested/photo.jpg', 'existing cloud photo');
    final value = await pair();
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
    'permission errors stop the entire scan without interpreting deletions',
    () async {
      await device.put('keep.txt', 'local');
      cloud.put('Backup/Selected/keep.txt', 'remote');
      final value = await pair();
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
    final value = await pair();
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
      final value = await pair();
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

  test('destination races never overwrite cloud files', () async {
    await device.put('file.txt', 'source');
    final value = await pair();
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

  test('Wi-Fi policy blocks work without losing pending files', () async {
    await device.put('file.txt', 'source');
    final value = await pair();
    device.wifi = false;
    await sync.run(value);
    expect(sync.error, contains('Wi-Fi'));
    expect(cloud.uploads, 0);
    device.wifi = true;
    await sync.run(value);
    expect(sync.error, isNull);
    expect(cloud.uploads, 1);
  });

  test(
    'missing native policy handler does not request or blame folder permission',
    () async {
      await device.put('file.txt', 'source');
      final value = await pair();
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
        backgroundService: background,
      );
      final value = await pair();
      await sync.run(value);
      expect(sync.error, isNull);
      await sync.run(value);
      expect(sync.error, isNull);
      expect(cloud.uploads, 1);
      expect(calls.where((method) => method == 'conditions'), hasLength(4));
      expect(calls, isNot(contains('pick')));
      expect(device.picks, 0);
    },
  );

  test(
    'backgrounding pauses between files, then manual run skips completed work',
    () async {
      await device.put('one.txt', 'one');
      await device.put('two.txt', 'two');
      final value = await pair();
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
      final value = await pair();
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

  test('iPhone saved pairs can run repeatedly', () async {
    sync.dispose();
    sync = controller(android: false);
    final value = await pair();
    await device.put('first.txt', 'one');
    await sync.run(value);
    await device.put('second.txt', 'two');
    await sync.run(value);
    expect(cloud.uploads, 2);
    expect(sync.error, isNull);
  });

  test('forgetting pairs removes only settings and history', () async {
    await device.put('file.txt', 'source');
    final value = await pair();
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
      await pair();
      await expectLater(
        sync.add('Nested', const DeviceFolder('different', 'other', 'other'), [
          'Backup',
          'Selected',
          'Child',
        ]),
        throwsFormatException,
      );
      await expectLater(
        sync.add(
          'Same grant',
          const DeviceFolder('grant', 'Selected', 'folder-id'),
          ['Other'],
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
}
