import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/phone_removal.dart';
import 'package:ncloud/features/backup/engine/sync_runner.dart';
import 'package:ncloud/features/backup/platform/album_folders.dart';
import 'package:ncloud/features/backup/platform/sync_run_lock.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../nextcloud_client_test.dart' as fixtures;
import '../../support/backup_fakes.dart';

/// The Android media library, answering list, export and the removal prompt.
class _Media {
  final items = <String, Map<String, Object?>>{};
  final contents = <String, List<int>>{};
  late Directory staging;
  final trashCalls = <List<String>>[];
  bool userSaysNo = false;
  int next = 1;

  void add(String folder, String name, List<int> bytes) {
    final id = 'image:${next++}';
    items[id] = {
      'id': id,
      'name': name,
      'size': bytes.length,
      'modified': 1700000000000,
      'contentType': 'image/jpeg',
      'folder': folder,
    };
    contents[id] = bytes;
  }

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map<dynamic, dynamic>? ?? {};
    switch (call.method) {
      case 'mediaAccess':
        return {'status': 'granted'};
      case 'mediaList':
        final all = items.values.toList()
          ..sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
        return all
            .skip(args['offset'] as int)
            .take(args['limit'] as int)
            .toList();
      case 'mediaExport':
        final id = args['id'] as String;
        final file = File('${staging.path}/${id.replaceAll(':', '_')}.part');
        await file.writeAsBytes(contents[id]!);
        return file.path;
      case 'mediaTrash':
        final ids = (args['ids'] as List).cast<String>();
        trashCalls.add(ids);
        if (userSaysNo) return <String>[];
        for (final id in ids) {
          items.remove(id);
        }
        return ids;
      case 'discard':
        final file = File(args['staged'] as String);
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

  group('Android library', () {
    late Directory root;
    late _Media media;
    late FakeServer server;
    late SyncJournal journal;
    late NativeFolderAccess access;

    final pair = FolderPair(
      id: 'lib',
      account: syncAccount(fixtures.account),
      name: 'All photos & videos',
      folder: const DeviceFolder.library(),
      remote: const ['Backup'],
      wifiOnly: false,
    );

    Future<void> backUp() async {
      final runner = SyncRunner(
        client: server,
        access: access,
        journal: journal,
        runLock: InProcessSyncRunLock(),
        foreground: () => true,
        accountKey: () => syncAccount(fixtures.account),
        onChanged: () {},
        progress: SyncProgress(),
      );
      await journal.save(pair);
      await runner.run(fixtures.account, pair);
      expect(runner.error, isNull);
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('trash');
      media = _Media()..staging = await Directory('${root.path}/s').create();
      server = FakeServer();
      journal = SyncJournal(
        path: '${root.path}/j.db',
        factory: databaseFactoryFfi,
      );
      access = NativeFolderAccess();
      messenger.setMockMethodCallHandler(
        NativeFolderAccess.channel,
        media.handle,
      );
    });
    tearDown(() async {
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null);
      await journal.close();
      await root.delete(recursive: true);
    });

    test(
      'clears one album that is safely backed up, and nothing else',
      () async {
        media.add('DCIM/Camera/', 'a.jpg', [1, 2, 3, 4]);
        media.add('Pictures/Screenshots/', 's1.png', [5, 6, 7]);
        media.add('Pictures/Screenshots/', 's2.png', [8, 9, 1]);
        await backUp();
        media.add('Pictures/Screenshots/', 'new.png', [4, 4, 4]);

        final targets = await removalTargets(access, pair);
        final shots = targets.firstWhere((t) => t.name == 'Screenshots');
        expect(shots.files, 3);
        final plan = await planRemoval(
          client: server,
          access: access,
          journal: journal,
          session: fixtures.account,
          pair: pair,
          target: shots,
        );
        expect(plan.removable, hasLength(2));
        expect(plan.kept.single.path.last, 'new.png');
        expect(plan.kept.single.reason, KeepReason.notBackedUp);

        final result = await removeFromPhone(
          client: server,
          access: access,
          remover: access,
          journal: journal,
          session: fixtures.account,
          pair: pair,
          plan: plan,
        );
        expect(result.removed, 2);
        expect(result.stopped, isFalse);
        expect(media.trashCalls, hasLength(1));
        expect(media.trashCalls.single, hasLength(2));
        expect(media.items.values.map((i) => i['name']).toSet(), {
          'a.jpg',
          'new.png',
        });
        expect(server.files, hasLength(3), reason: 'the server is untouched');
      },
    );

    test('declining the phone\'s prompt removes nothing', () async {
      media.add('DCIM/Camera/', 'a.jpg', [1, 2, 3, 4]);
      await backUp();
      media.userSaysNo = true;
      final target = (await removalTargets(access, pair)).single;
      final plan = await planRemoval(
        client: server,
        access: access,
        journal: journal,
        session: fixtures.account,
        pair: pair,
        target: target,
      );
      final result = await removeFromPhone(
        client: server,
        access: access,
        remover: access,
        journal: journal,
        session: fixtures.account,
        pair: pair,
        plan: plan,
      );
      expect(result.removed, 0);
      expect(result.stopped, isTrue);
      expect(media.items, hasLength(1));
    });
  });

  group('iPhone Photos', () {
    final calls = <Map<dynamic, dynamic>>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        if (call.method == 'deleteListed') {
          calls.add(call.arguments as Map<dynamic, dynamic>);
          // The phone removes all but the last name.
          final names = (call.arguments['names'] as List).cast<String>();
          return names.take(names.length - 1).toList();
        }
        return null;
      });
    });
    tearDown(
      () =>
          messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null),
    );

    RemovalFile file(String folder, String name) =>
        (path: [folder, name], entry: DeviceEntry(name, false, 1, 1));

    test('a plain album is named by its own token', () async {
      final token = cameraRollWith(const []).token;
      final gone = await NativeFolderAccess().moveToTrash(token, [
        (path: ['a.heic'], entry: DeviceEntry('a.heic', false, 1, 1)),
        (path: ['b.heic'], entry: DeviceEntry('b.heic', false, 1, 1)),
      ]);
      expect(calls.single['token'], token);
      expect(calls.single['names'], ['a.heic', 'b.heic']);
      expect(gone, [
        ['a.heic'],
      ], reason: 'only what the phone confirmed');
    });

    test(
      'album folders are removed through the whole library listing',
      () async {
        final folder = cameraRollWith([
          AlbumChoice('photos:${base64Encode(utf8.encode('w1'))}', 'W1'),
        ]);
        final gone = await NativeFolderAccess().moveToTrash(folder.token, [
          file('W1', 'a.heic'),
          file('W1', 'b.heic'),
        ]);
        expect(calls.single['token'], cameraRollToken);
        expect(gone, [
          ['W1', 'a.heic'],
        ]);
      },
    );

    test(
      'nothing to remove asks nothing, and other sources are refused',
      () async {
        expect(await NativeFolderAccess().moveToTrash('x', const []), isEmpty);
        expect(calls, isEmpty);
        await expectLater(
          NativeFolderAccess().moveToTrash('content://folder', [
            file('a', 'b.jpg'),
          ]),
          throwsA(isA<UnsupportedError>()),
        );
      },
    );
  });
}
