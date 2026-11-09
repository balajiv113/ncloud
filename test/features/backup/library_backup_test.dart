import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/sync_engine.dart';
import 'package:ncloud/features/backup/engine/sync_runner.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/backup/platform/sync_run_lock.dart';
import 'package:ncloud/features/backup/state/sync_journal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../nextcloud_client_test.dart' as fixtures;
import '../../support/backup_fakes.dart';

/// The phone's media library, answering the native calls.
class _Library {
  final items = <String, Map<String, Object?>>{};
  final contents = <String, List<int>>{};
  late Directory staging;
  var permission = 'granted';
  var nextId = 1;

  String add(
    String folder,
    String name,
    List<int> bytes, {
    int modified = 1700000000000,
    String kind = 'image',
  }) {
    final id = '$kind:${nextId++}';
    items[id] = {
      'id': id,
      'name': name,
      'size': bytes.length,
      'modified': modified,
      'contentType': kind == 'image' ? 'image/jpeg' : 'video/mp4',
      'folder': folder,
    };
    contents[id] = bytes;
    return id;
  }

  Future<Object?> handle(MethodCall call) async {
    switch (call.method) {
      case 'mediaAccess':
        return {'status': permission};
      case 'mediaList':
        final all = items.values.toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        final offset = call.arguments['offset'] as int;
        final limit = call.arguments['limit'] as int;
        return all.skip(offset).take(limit).toList();
      case 'mediaExport':
        final id = call.arguments['id'] as String;
        final file = File('${staging.path}/${id.replaceAll(':', '_')}.part');
        await file.writeAsBytes(contents[id]!);
        return file.path;
      case 'discard':
        final file = File(call.arguments['staged'] as String);
        if (await file.exists()) await file.delete();
        return null;
      case 'conditions':
        return {'wifi': true, 'charging': true};
    }
    return null;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late _Library library;
  late FakeServer server;
  late SyncJournal journal;
  late NativeFolderAccess access;

  FolderPair libraryPair() => FolderPair(
    id: 'lib',
    account: syncAccount(fixtures.account),
    name: 'All photos & videos',
    folder: const DeviceFolder.library(),
    remote: const ['Backup'],
    wifiOnly: false,
  );

  Future<SyncProgress> runLibrary(FolderPair pair) async {
    final progress = SyncProgress();
    final runner = SyncRunner(
      client: server,
      access: access,
      journal: journal,
      runLock: InProcessSyncRunLock(),
      foreground: () => true,
      accountKey: () => syncAccount(fixtures.account),
      onChanged: () {},
      progress: progress,
    );
    await journal.save(pair);
    final result = await runner.run(fixtures.account, pair);
    expect(runner.error, isNull, reason: result.state.toString());
    return progress;
  }

  List<int> bytes(int i) => [i, i + 1, i + 2, 9, 9, 9];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('library');
    library = _Library()
      ..staging = await Directory('${root.path}/stage').create();
    server = FakeServer();
    journal = SyncJournal(
      path: '${root.path}/j.db',
      factory: databaseFactoryFfi,
    );
    access = NativeFolderAccess();
    messenger.setMockMethodCallHandler(
      NativeFolderAccess.channel,
      library.handle,
    );
  });
  tearDown(() async {
    messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null);
    await journal.close();
    await root.delete(recursive: true);
  });

  test(
    'backs up the library into folders named like the phone\'s own',
    () async {
      library.add(
        'DCIM/Camera/',
        'IMG_1.jpg',
        bytes(1),
        modified: 1700000003000,
      );
      library.add(
        'DCIM/Camera/',
        'VID_2.mp4',
        bytes(2),
        kind: 'video',
        modified: 1700000002000,
      );
      library.add(
        'Pictures/Screenshots/',
        'shot.png',
        bytes(3),
        modified: 1700000001000,
      );
      final progress = await runLibrary(libraryPair());
      expect(server.files.keys.toSet(), {
        'Backup/Phone/Camera/IMG_1.jpg',
        'Backup/Phone/Camera/VID_2.mp4',
        'Backup/Phone/Screenshots/shot.png',
      });
      expect(progress.transferred, 3);
      expect(progress.found, 3);
      // The original's time is kept, not the time of the upload.
      expect(
        server.uploadLog.firstWhere((u) => u.path.last == 'IMG_1.jpg').modified,
        DateTime.fromMillisecondsSinceEpoch(1700000003000),
      );
    },
  );

  test('a repeat run finds nothing to do', () async {
    for (var i = 0; i < 40; i++) {
      library.add('DCIM/Camera/', 'IMG_$i.jpg', bytes(i));
    }
    await runLibrary(libraryPair());
    final uploads = server.uploads;
    final again = await runLibrary(libraryPair());
    expect(server.uploads, uploads);
    expect(again.alreadyBackedUp, 40);
    expect(again.toUpload, 0);
  });

  test('new photos are picked up on the next run', () async {
    library.add('DCIM/Camera/', 'IMG_1.jpg', bytes(1));
    await runLibrary(libraryPair());
    library.add('DCIM/Camera/', 'IMG_2.jpg', bytes(2));
    library.add('DCIM/Camera/', 'IMG_3.jpg', bytes(3));
    final progress = await runLibrary(libraryPair());
    expect(progress.transferred, 2);
    expect(server.uploads, 3);
  });

  test(
    'a photo moved to another phone folder is moved on the server',
    () async {
      final id = library.add('DCIM/Camera/', 'IMG_1.jpg', bytes(1));
      await runLibrary(libraryPair());
      expect(server.files.keys, contains('Backup/Phone/Camera/IMG_1.jpg'));
      // Moved into an album in the gallery: the same photo, now in Trips.
      library.items[id]!['folder'] = 'Pictures/Trips/';
      final progress = await runLibrary(libraryPair());
      expect(server.uploads, 1, reason: 'no second upload');
      expect(server.moves, 1);
      expect(progress.moved, 1);
      expect(server.files.keys.where((n) => n.startsWith('Backup/Phone/')), [
        'Backup/Phone/Trips/IMG_1.jpg',
      ]);
    },
  );

  test('a photo deleted from the phone stays on the server', () async {
    final id = library.add('DCIM/Camera/', 'IMG_1.jpg', bytes(1));
    library.add('DCIM/Camera/', 'IMG_2.jpg', bytes(2));
    await runLibrary(libraryPair());
    library.items.remove(id);
    library.contents.remove(id);
    await runLibrary(libraryPair());
    expect(server.files.keys, contains('Backup/Phone/Camera/IMG_1.jpg'));
    expect(server.files.length, 2);
  });

  test('a folder another backup covers is left to that backup', () async {
    library.add('DCIM/Camera/', 'IMG_1.jpg', bytes(1));
    library.add('Pictures/Screenshots/', 'shot.png', bytes(3));
    await journal.save(
      FolderPair(
        id: 'camera',
        account: syncAccount(fixtures.account),
        name: 'Camera',
        folder: const DeviceFolder(
          'content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera',
          'Camera',
          'camera',
        ),
        remote: const ['Backup'],
      ),
    );
    await runLibrary(libraryPair());
    expect(server.files.keys, ['Backup/Phone/Screenshots/shot.png']);
  });

  test(
    'losing access stops the run with a reason, and nothing is lost',
    () async {
      library.add('DCIM/Camera/', 'IMG_1.jpg', bytes(1));
      library.permission = 'denied';
      final progress = SyncProgress();
      final runner = SyncRunner(
        client: server,
        access: access,
        journal: journal,
        runLock: InProcessSyncRunLock(),
        foreground: () => true,
        accountKey: () => syncAccount(fixtures.account),
        onChanged: () {},
        progress: progress,
      );
      final pair = libraryPair();
      await journal.save(pair);
      await runner.run(fixtures.account, pair);
      expect(runner.error, contains('photos and videos was removed'));
      expect(runner.errorCode, 'media_permission');
      expect(server.uploads, 0);
    },
  );

  test('duplicate names in one folder both get backed up', () async {
    library.add('DCIM/Camera/', 'IMG.jpg', bytes(1));
    library.add('DCIM/Camera/', 'IMG.jpg', bytes(2));
    await runLibrary(libraryPair());
    expect(server.files.length, 2);
    expect(server.files.keys, contains('Backup/Phone/Camera/IMG.jpg'));
  });
}
