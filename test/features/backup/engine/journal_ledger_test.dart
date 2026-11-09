import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/failure_policy.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/backup/state/sync_journal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late SyncJournal journal;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('journal');
    journal = SyncJournal(
      path: '${root.path}/j.db',
      factory: databaseFactoryFfi,
    );
  });
  tearDown(() async {
    await journal.close();
    await root.delete(recursive: true);
  });

  Receipt receipt(int i) => Receipt(
    path: ['dir', 'IMG_$i.jpg'],
    version: 'v$i',
    target: ['dir', 'IMG_$i.jpg'],
    targetVersion: '"e$i"|10',
    fingerprint: 'f$i',
    size: 10,
  );

  group('receipts', () {
    test('are written in one batch and read back in groups', () async {
      await journal.confirmAll('p', [
        for (var i = 0; i < 1000; i++) receipt(i),
      ]);
      final found = await journal.receiptsFor('p', [
        for (var i = 0; i < 1000; i++) ['dir', 'IMG_$i.jpg'],
        ['dir', 'missing.jpg'],
      ]);
      expect(found.length, 1000);
      final one = found['["dir","IMG_7.jpg"]']!;
      expect(one.version, 'v7');
      expect(one.fingerprint, 'f7');
      expect(one.size, 10);
      expect(one.target, ['dir', 'IMG_7.jpg']);
    });

    test('keep names with quotes and unicode apart', () async {
      final odd = ['A "quoted" é.jpg'];
      await journal.confirmAll('p', [
        Receipt(path: odd, version: 'v', target: odd, targetVersion: 't'),
      ]);
      expect(await journal.receiptsFor('p', [odd]), hasLength(1));
    });

    test('belong to one pair', () async {
      await journal.confirmAll('a', [receipt(1)]);
      expect(
        await journal.receiptsFor('b', [
          ['dir', 'IMG_1.jpg'],
        ]),
        isEmpty,
      );
    });

    test('an empty batch is fine and the single write still works', () async {
      await journal.confirmAll('p', []);
      await journal.confirm(
        'p',
        ['x.jpg'],
        'v',
        ['x.jpg'],
        't',
        fingerprint: 'abc',
        size: 3,
      );
      expect(
        (await journal.receipt('p', 'local', ['x.jpg']))!['fingerprint'],
        'abc',
      );
    });
  });

  group('failures', () {
    FileFailure failure(String name, {String message = 'bad'}) =>
        FileFailure(path: [name], message: message, code: 'folder_io');

    test('are kept with the reason, newest first', () async {
      await journal.recordFailure(
        'p',
        failure('a.jpg', message: 'first'),
        'v1',
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await journal.recordFailure(
        'p',
        failure('b.jpg', message: 'second'),
        'v1',
      );
      final all = await journal.failures('p');
      expect(all.map((f) => f.message), ['second', 'first']);
      expect(all.first.code, 'folder_io');
      expect(await journal.failureCount('p'), 2);
    });

    test(
      'count attempts for the same version and restart for a changed file',
      () async {
        await journal.recordFailure('p', failure('a.jpg'), 'v1');
        await journal.recordFailure('p', failure('a.jpg'), 'v1');
        expect((await journal.failures('p')).single.attempts, 2);
        await journal.recordFailure('p', failure('a.jpg'), 'v2');
        expect((await journal.failures('p')).single.attempts, 1);
      },
    );

    test(
      'are looked up for the files in a group and cleared one by one',
      () async {
        await journal.recordFailure('p', failure('a.jpg'), 'v1');
        final found = await journal.failuresFor('p', [
          ['a.jpg'],
          ['b.jpg'],
        ]);
        expect(found.keys, ['["a.jpg"]']);
        await journal.clearFailure('p', ['a.jpg']);
        expect(await journal.failureCount('p'), 0);
      },
    );

    test('a retry gives every file a fresh start', () async {
      await journal.recordFailure('p', failure('a.jpg'), 'v1');
      await journal.recordFailure('p', failure('a.jpg'), 'v1');
      await journal.resetFailures('p');
      expect((await journal.failures('p')).single.attempts, 0);
    });

    test('go when a pair or the account is forgotten', () async {
      final pair = FolderPairForTests.make('p');
      await journal.save(pair);
      await journal.recordFailure('p', failure('a.jpg'), 'v1');
      await journal.confirmAll('p', [receipt(1)]);
      await journal.forget('p');
      expect(await journal.failureCount('p'), 0);
      expect(
        await journal.receiptsFor('p', [
          ['dir', 'IMG_1.jpg'],
        ]),
        isEmpty,
      );
    });
  });

  test('an older journal upgrades without losing a single receipt', () async {
    final path = '${root.path}/old.db';
    final old = await databaseFactoryFfi.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: (db, _) async {
          await db.execute(
            'CREATE TABLE pairs (id TEXT PRIMARY KEY, account TEXT NOT NULL, payload TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE run_state (pair TEXT PRIMARY KEY, payload TEXT NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE sync_sessions (account TEXT PRIMARY KEY, enabled INTEGER NOT NULL)',
          );
          await db.execute(
            'CREATE TABLE receipts (pair TEXT NOT NULL, side TEXT NOT NULL, '
            'path TEXT NOT NULL, version TEXT NOT NULL, target TEXT NOT NULL, '
            'target_version TEXT NOT NULL, PRIMARY KEY(pair,side,path))',
          );
          for (var i = 0; i < 50; i++) {
            await db.insert('receipts', {
              'pair': 'p',
              'side': 'local',
              'path': '["old$i.jpg"]',
              'version': 'v$i',
              'target': '["old$i.jpg"]',
              'target_version': 't$i',
            });
          }
        },
      ),
    );
    await old.close();
    final upgraded = SyncJournal(path: path, factory: databaseFactoryFfi);
    addTearDown(upgraded.close);
    final found = await upgraded.receiptsFor('p', [
      for (var i = 0; i < 50; i++) ['old$i.jpg'],
    ]);
    expect(found.length, 50);
    expect(found['["old3.jpg"]']!.version, 'v3');
    expect(found['["old3.jpg"]']!.fingerprint, isNull);
    // The new parts work on the upgraded file.
    await upgraded.recordFailure(
      'p',
      const FileFailure(path: ['x'], message: 'm'),
      'v',
    );
    expect(await upgraded.failureCount('p'), 1);
    await upgraded.confirmAll('p', [receipt(1)]);
    expect(
      (await upgraded.receiptsFor('p', [
        ['dir', 'IMG_1.jpg'],
      ])).length,
      1,
    );
  });
}

/// A minimal pair for tests that only need one saved.
class FolderPairForTests {
  static FolderPair make(String id) => FolderPair(
    id: id,
    account: 'a|b',
    name: 'Camera',
    folder: const DeviceFolder('t', 'Camera', 'camera'),
    remote: const ['Backup'],
  );
}
