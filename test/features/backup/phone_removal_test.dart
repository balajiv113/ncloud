import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/phone_removal.dart';
import 'package:ncloud/features/backup/engine/sync_engine.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../nextcloud_client_test.dart' show account;
import '../../support/backup_fakes.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late FakeServer server;
  late RemovableDevice device;
  late SyncJournal journal;

  FolderPair pair() => FolderPair(
    id: 'p',
    account: 'a|b',
    name: 'Camera',
    folder: const DeviceFolder('t', 'Camera', 'camera'),
    remote: const ['Backup'],
    wifiOnly: false,
  );

  Future<void> run() => SyncEngine(
    client: server,
    access: device,
    journal: journal,
    progress: SyncProgress(),
    check: (_) {},
    onChanged: () {},
  ).run(account, pair());

  Future<RemovalPlan> plan([List<String> path = const ['Trips']]) async {
    final targets = await removalTargets(device, pair());
    final target = targets.firstWhere(
      (t) => t.path.join('/') == path.join('/'),
    );
    return planRemoval(
      client: server,
      access: device,
      journal: journal,
      session: account,
      pair: pair(),
      target: target,
    );
  }

  Future<RemovalResult> remove(
    RemovalPlan value, {
    bool Function()? stop,
    void Function(int, int)? progress,
  }) => removeFromPhone(
    client: server,
    access: device,
    remover: device,
    journal: journal,
    session: account,
    pair: pair(),
    plan: value,
    shouldStop: stop,
    onProgress: progress,
  );

  List<int> bytes(int i) => [i, i + 1, i + 2, 9, 9, 9];

  setUp(() async {
    root = await Directory.systemTemp.createTemp('removal');
    server = FakeServer();
    device = RemovableDevice(await Directory('${root.path}/s').create());
    journal = SyncJournal(
      path: '${root.path}/j.db',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await journal.close();
    await root.delete(recursive: true);
  });

  group('what can be cleared', () {
    test('lists albums and folders with their size, biggest first', () async {
      device.add('Trips/a.jpg', bytes(1));
      device.add('Trips/b.jpg', bytes(2));
      device.add('Screenshots/c.jpg', bytes(3));
      device.add('top.jpg', bytes(4));
      final targets = await removalTargets(device, pair());
      expect(
        [for (final t in targets) (t.name, t.files)],
        [('Trips', 2), ('Camera', 1), ('Screenshots', 1)],
      );
      expect(targets.first.bytes, 12);
    });
  });

  group('what is safe to remove', () {
    test('only files backed up and still on the server unchanged', () async {
      device.add('Trips/a.jpg', bytes(1));
      device.add('Trips/b.jpg', bytes(2));
      await run();
      final result = await plan();
      expect(result.removable.map((f) => f.path.last).toSet(), {
        'a.jpg',
        'b.jpg',
      });
      expect(result.kept, isEmpty);
      expect(result.bytes, 12);
    });

    test('a file not backed up yet stays', () async {
      device.add('Trips/a.jpg', bytes(1));
      await run();
      device.add('Trips/new.jpg', bytes(2));
      final result = await plan();
      expect(result.removable.map((f) => f.path.last), ['a.jpg']);
      expect(result.kept.single.path.last, 'new.jpg');
      expect(result.kept.single.reason, KeepReason.notBackedUp);
    });

    test('a file edited since it was backed up stays', () async {
      device.add('Trips/a.jpg', bytes(1), modified: 1000);
      await run();
      device.add('Trips/a.jpg', bytes(7), modified: 2000);
      final result = await plan();
      expect(result.removable, isEmpty);
      expect(result.kept.single.reason, KeepReason.notBackedUp);
    });

    test('a file removed from the server stays', () async {
      device.add('Trips/a.jpg', bytes(1));
      device.add('Trips/b.jpg', bytes(2));
      await run();
      server.files.remove('Backup/Camera/Trips/a.jpg');
      final result = await plan();
      expect(result.removable.map((f) => f.path.last), ['b.jpg']);
      expect(result.kept.single.path.last, 'a.jpg');
      expect(result.kept.single.reason, KeepReason.notOnServer);
    });

    test('a file changed on the server stays', () async {
      device.add('Trips/a.jpg', bytes(1));
      await run();
      server.put('Backup/Camera/Trips/a.jpg', [9, 9]);
      final result = await plan();
      expect(result.removable, isEmpty);
      expect(result.kept.single.reason, KeepReason.notOnServer);
    });

    test('a removed server folder keeps everything in it', () async {
      device.add('Trips/a.jpg', bytes(1));
      await run();
      server.files.clear();
      server.folders.remove('Backup/Camera/Trips');
      expect((await plan()).kept.single.reason, KeepReason.notOnServer);
    });

    test('the parts of one photo go together or not at all', () async {
      device.add('Trips/live.heic', bytes(1), id: 'asset-1');
      device.add('Trips/live.mov', bytes(2), id: 'asset-1');
      device.add('Trips/other.heic', bytes(3), id: 'asset-2');
      await run();
      server.files.remove('Backup/Camera/Trips/live.mov');
      final result = await plan();
      expect(result.removable.map((f) => f.path.last), ['other.heic']);
      final reasons = {for (final k in result.kept) k.path.last: k.reason};
      expect(reasons['live.mov'], KeepReason.notOnServer);
      expect(reasons['live.heic'], KeepReason.partOfUnverified);
    });

    test('planning changes nothing', () async {
      device.add('Trips/a.jpg', bytes(1));
      await run();
      final uploads = server.uploads;
      await plan();
      expect(device.entries, hasLength(1));
      expect(server.files, hasLength(1));
      expect(server.uploads, uploads);
      expect(device.prompts, isEmpty);
    });
  });

  group('removing', () {
    test('a big album goes in batches, each one asked about', () async {
      for (var i = 0; i < 450; i++) {
        device.add('Trips/f$i.jpg', bytes(i));
      }
      await run();
      final seen = <int>[];
      final result = await remove(
        await plan(),
        progress: (done, total) => seen.add(done),
      );
      expect(result.stopped, isFalse);
      expect(result.removed, 450);
      expect(device.prompts, [200, 200, 50]);
      expect(device.entries, isEmpty);
      expect(seen, [0, 200, 400, 450]);
      expect(result.bytes, 450 * 6);
    });

    test('the server and the backup records are never touched', () async {
      device.add('Trips/a.jpg', bytes(1));
      await run();
      await remove(await plan());
      expect(server.files.keys, ['Backup/Camera/Trips/a.jpg']);
      expect(
        await journal.receiptsFor('p', [
          ['Trips', 'a.jpg'],
        ]),
        hasLength(1),
      );
      // The backup does not bring it back, and does not re-upload anything.
      final uploads = server.uploads;
      await run();
      expect(server.uploads, uploads);
      expect(device.entries, isEmpty);
    });

    test('declining a prompt stops there, keeping what was removed', () async {
      for (var i = 0; i < 450; i++) {
        device.add('Trips/f$i.jpg', bytes(i));
      }
      await run();
      device.declineAt = 2;
      final result = await remove(await plan());
      expect(result.stopped, isTrue);
      expect(result.removed, 200);
      expect(device.entries, hasLength(250));
      expect(device.prompts, hasLength(2));
    });

    test(
      'a batch is checked again, so a change since planning stops it',
      () async {
        for (var i = 0; i < 450; i++) {
          device.add('Trips/f$i.jpg', bytes(i));
        }
        await run();
        final value = await plan();
        device.beforePrompt = (n) {
          // After the first prompt the server loses a file from the next batch.
          if (n == 1) {
            server.files.remove(
              'Backup/Camera/Trips/${value.removable[250].path.last}',
            );
          }
        };
        final result = await remove(value);
        expect(result.stopped, isTrue);
        expect(result.removed, 200);
        expect(device.prompts, [
          200,
        ], reason: 'the second batch was never offered');
        expect(result.reason, contains('changed'));
      },
    );

    test('a file that changed on the phone since planning stops it', () async {
      device.add('Trips/a.jpg', bytes(1), modified: 1000);
      await run();
      final value = await plan();
      device.add('Trips/a.jpg', bytes(5), modified: 5000);
      final result = await remove(value);
      expect(result.stopped, isTrue);
      expect(result.removed, 0);
      expect(device.prompts, isEmpty);
      expect(device.entries, hasLength(1));
    });

    test('stopping between batches leaves the rest alone', () async {
      for (var i = 0; i < 450; i++) {
        device.add('Trips/f$i.jpg', bytes(i));
      }
      await run();
      var stop = false;
      device.beforePrompt = (_) => stop = true;
      final result = await remove(await plan(), stop: () => stop);
      expect(result.stopped, isTrue);
      expect(result.removed, 200);
      expect(device.entries, hasLength(250));
    });

    test('nothing removable asks nothing', () async {
      device.add('Trips/a.jpg', bytes(1));
      final value = await plan();
      expect(value.isEmpty, isTrue);
      final result = await remove(value);
      expect(result.removed, 0);
      expect(device.prompts, isEmpty);
    });
  });
}
