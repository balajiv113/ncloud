import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/backup/engine/sync_engine.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/backup/state/sync_journal.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../../nextcloud_client_test.dart' show account;
import '../../../support/backup_fakes.dart';

void main() {
  sqfliteFfiInit();
  late Directory root;
  late FakeServer server;
  late FakeDevice device;
  late SyncJournal journal;
  late SyncProgress progress;
  late int changes;
  late List<Duration> pauses;
  var stopAfter = -1;
  var now = DateTime(2025);

  FolderPair pair({int concurrency = 1}) => FolderPair(
    id: 'p',
    account: 'a|b',
    name: 'Camera',
    folder: const DeviceFolder('t', 'Camera', 'camera'),
    remote: const ['Backup'],
    wifiOnly: false,
    uploadConcurrency: concurrency,
  );

  SyncEngine engine() => SyncEngine(
    client: server,
    access: device,
    journal: journal,
    progress: progress,
    check: (_) {
      if (stopAfter >= 0 && server.uploads >= stopAfter) throw SyncStopped();
    },
    onChanged: () => changes++,
    clock: () => now = now.add(const Duration(milliseconds: 1)),
    pause: (duration) async => pauses.add(duration),
  );

  Future<void> run({int concurrency = 1}) async {
    progress.reset();
    await engine().run(account, pair(concurrency: concurrency));
  }

  List<int> bytes(int i) => List.filled(32, i % 251);

  setUp(() async {
    root = await Directory.systemTemp.createTemp('engine');
    await Directory('${root.path}/stage').create();
    server = FakeServer();
    device = FakeDevice(Directory('${root.path}/stage'));
    journal = SyncJournal(
      path: '${root.path}/j.db',
      factory: databaseFactoryFfi,
    );
    progress = SyncProgress();
    changes = 0;
    pauses = [];
    stopAfter = -1;
  });
  tearDown(() async {
    await journal.close();
    await root.delete(recursive: true);
  });

  group('a very large folder', () {
    test('costs the server nothing per file', () async {
      for (var i = 0; i < 1500; i++) {
        device.add('IMG_$i.jpg', bytes(i), modified: 1700000000000 + i);
      }
      await run(concurrency: 3);
      expect(server.uploads, 1500);
      // The server is never asked to list, however big the folder is.
      expect(server.listings, 0);
      expect(server.entriesListed, 0);
      // One check for the destination and one for the folder, not one per file.
      expect(server.stats, lessThan(10));
      expect(server.folderRequests, lessThan(4));
      expect(progress.transferred, 1500);
      expect(progress.found, 1500);
      expect(device.discards, 1500);
      expect(
        (await journal.receiptsFor('p', [
          for (var i = 0; i < 1500; i++) ['IMG_$i.jpg'],
        ])).length,
        1500,
      );
    });

    test('a repeat run does no server work and no exports', () async {
      for (var i = 0; i < 600; i++) {
        device.add('IMG_$i.jpg', bytes(i));
      }
      await run();
      server.stats = 0;
      final exports = device.exports;
      final uploads = server.uploads;
      await run();
      expect(server.uploads, uploads);
      expect(device.exports, exports);
      expect(server.listings, 0);
      expect(server.stats, lessThan(3));
      expect(progress.alreadyBackedUp, 600);
      expect(progress.toUpload, 0);
    });

    test('progress updates are throttled, not one per file', () async {
      for (var i = 0; i < 800; i++) {
        device.add('IMG_$i.jpg', bytes(i));
      }
      await run();
      expect(changes, lessThan(80));
    });
  });

  group('what is sent', () {
    test(
      'carries the fingerprint and modification time, and records both',
      () async {
        device.add('a.jpg', bytes(7), modified: 1700000123000);
        await run();
        final sent = server.uploadLog.single;
        expect(sent.sha1, sha1Of(bytes(7)));
        expect(
          sent.modified,
          DateTime.fromMillisecondsSinceEpoch(1700000123000),
        );
        final receipt = (await journal.receiptsFor('p', [
          ['a.jpg'],
        ])).values.single;
        expect(receipt.fingerprint, sha1Of(bytes(7)));
        expect(receipt.size, 32);
        expect(
          receipt.targetVersion,
          startsWith(server.files['Backup/Camera/a.jpg']!.etag),
        );
      },
    );

    test('newest files go first', () async {
      device.add('old.jpg', bytes(1), modified: 1000);
      device.add('new.jpg', bytes(2), modified: 3000);
      device.add('mid.jpg', bytes(3), modified: 2000);
      await run();
      expect(server.uploadLog.map((u) => u.path.last), [
        'new.jpg',
        'mid.jpg',
        'old.jpg',
      ]);
    });

    test('an empty folder still creates the destination', () async {
      await run();
      expect(server.folders, contains('Backup/Camera'));
      expect(server.uploads, 0);
    });
  });

  group('a file already on the server', () {
    test('the same content is recognised, not uploaded twice', () async {
      device.add('a.jpg', bytes(5));
      server.put('Backup/Camera/a.jpg', bytes(5), sha1: sha1Of(bytes(5)));
      await run();
      expect(server.uploads, 0);
      expect(progress.recognised, 1);
      expect(progress.transferred, 0);
      expect(
        (await journal.receiptsFor('p', [
          ['a.jpg'],
        ])),
        isNotEmpty,
      );
      // And the next run has nothing to do.
      await run();
      expect(progress.alreadyBackedUp, 1);
    });

    test('different content is kept beside it, never overwritten', () async {
      device.add('a.jpg', bytes(5));
      server.put('Backup/Camera/a.jpg', bytes(9), sha1: sha1Of(bytes(9)));
      await run();
      expect(server.files['Backup/Camera/a.jpg']!.bytes, bytes(9));
      final copy = server.files.keys.singleWhere(
        (n) => n.contains('ncloud device'),
      );
      expect(server.files[copy]!.bytes, bytes(5));
      expect(progress.conflicts, 1);
    });

    test('the same size but no stored fingerprint is not trusted', () async {
      device.add('a.jpg', bytes(5));
      server.put('Backup/Camera/a.jpg', bytes(6));
      await run();
      expect(
        server.files.keys.where((n) => n.contains('ncloud device')),
        hasLength(1),
      );
    });
  });

  group('when something goes wrong', () {
    test('one bad file is recorded and the rest carry on', () async {
      for (var i = 0; i < 5; i++) {
        device.add('f$i.jpg', bytes(i), modified: 1000 + i);
      }
      device.beforeExport = (name) {
        if (name == 'f2.jpg') {
          throw const FormatException('Cannot read this file.');
        }
      };
      await run();
      expect(server.uploads, 4);
      expect(progress.failed, 1);
      expect(progress.transferred, 4);
      final failure = (await journal.failures('p')).single;
      expect(failure.path, ['f2.jpg']);
      expect(failure.message, 'Cannot read this file.');
      expect(device.staging.listSync(), isEmpty);
    });

    test('a failed file is tried again and its failure cleared', () async {
      device.add('a.jpg', bytes(1));
      var broken = true;
      device.beforeExport = (_) {
        if (broken) throw const FormatException('Cannot read this file.');
      };
      await run();
      expect(await journal.failureCount('p'), 1);
      broken = false;
      await run();
      expect(server.uploads, 1);
      expect(await journal.failureCount('p'), 0);
    });

    test(
      'a file that keeps failing stops being retried until the user retries',
      () async {
        device.add('a.jpg', bytes(1));
        device.beforeExport = (_) =>
            throw const FormatException('Cannot read this file.');
        for (var i = 0; i < 5; i++) {
          await run();
        }
        final exports = device.exports;
        await run();
        expect(device.exports, exports, reason: 'blocked, so not even read');
        expect(progress.blocked, 1);
        expect(progress.problems, 1);
        await journal.resetFailures('p');
        await run();
        expect(device.exports, greaterThan(exports));
      },
    );

    test('a changed file gets a fresh start', () async {
      device.add('a.jpg', bytes(1), modified: 1000);
      device.beforeExport = (_) =>
          throw const FormatException('Cannot read this file.');
      for (var i = 0; i < 6; i++) {
        await run();
      }
      device.beforeExport = null;
      device.add('a.jpg', bytes(2), modified: 2000);
      await run();
      expect(server.uploads, 1);
    });

    test(
      'temporary failures are retried after a pause, then succeed',
      () async {
        device.add('a.jpg', bytes(1));
        server.beforeUpload = (path, attempt) {
          if (attempt <= 2) {
            throw const CloudException(
              'Server busy',
              statusCode: 503,
              retryable: true,
            );
          }
        };
        await run();
        expect(server.uploads, 1);
        expect(progress.failed, 0);
        // Two retries, with growing pauses; they are split into short steps.
        expect(
          pauses.fold(Duration.zero, (a, b) => a + b),
          greaterThan(const Duration(seconds: 6)),
        );
      },
    );

    test(
      'a connection that stays down stops the run, and resumes later',
      () async {
        for (var i = 0; i < 6; i++) {
          device.add('f$i.jpg', bytes(i), modified: 1000 + i);
        }
        server.beforeUpload = (path, attempt) =>
            throw const SocketException('unreachable');
        await expectLater(
          run(),
          throwsA(
            isA<CloudException>().having(
              (e) => e.message,
              'message',
              contains('connection to your server was lost'),
            ),
          ),
        );
        // It gave up after two files, not six, and nothing was lost.
        expect(await journal.failureCount('p'), 2);
        server.beforeUpload = null;
        await run();
        expect(server.uploads, 6);
      },
    );

    test('an expired sign-in stops at once and keeps what was done', () async {
      for (var i = 0; i < 6; i++) {
        device.add('f$i.jpg', bytes(i), modified: 1000 + (5 - i));
      }
      server.beforeUpload = (path, attempt) {
        if (server.uploads >= 3) {
          throw const CloudException('Sign-in expired', statusCode: 401);
        }
      };
      await expectLater(run(), throwsA(isA<CloudException>()));
      expect(server.uploads, 3);
      expect(
        (await journal.receiptsFor('p', [
          for (var i = 0; i < 6; i++) ['f$i.jpg'],
        ])).length,
        3,
        reason: 'receipts for finished uploads are saved',
      );
      expect(await journal.failureCount('p'), 0);
    });

    test('a full server stops the run', () async {
      device.add('a.jpg', bytes(1));
      device.add('b.jpg', bytes(2));
      server.beforeUpload = (path, attempt) =>
          throw const CloudException('Full', statusCode: 507);
      await expectLater(run(), throwsA(isA<CloudException>()));
      expect(progress.failed, 0, reason: 'not blamed on a file');
    });

    test('many failures in a row stop the run with a clear reason', () async {
      for (var i = 0; i < 25; i++) {
        device.add('f$i.jpg', bytes(i), modified: 1000 + i);
      }
      device.beforeExport = (_) =>
          throw const FormatException('Cannot read this file.');
      await expectLater(
        run(),
        throwsA(
          isA<CloudException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('10 files in a row'),
              contains('Cannot read this file.'),
            ),
          ),
        ),
      );
      expect(progress.failed, 10);
    });

    test('a stop request keeps the receipts of what finished', () async {
      for (var i = 0; i < 20; i++) {
        device.add('f$i.jpg', bytes(i), modified: 1000 + i);
      }
      stopAfter = 7;
      await expectLater(run(), throwsA(isA<SyncStopped>()));
      expect(server.uploads, 7);
      expect(
        (await journal.receiptsFor('p', [
          for (var i = 0; i < 20; i++) ['f$i.jpg'],
        ])).length,
        7,
      );
      stopAfter = -1;
      await run();
      expect(server.uploads, 20);
      expect(server.files.length, 20, reason: 'nothing was uploaded twice');
    });

    test(
      'Wi-Fi is required when asked for, and checked once per run',
      () async {
        device.add('a.jpg', bytes(1));
        device.wifi = false;
        final wifiOnly = FolderPair(
          id: 'p',
          account: 'a|b',
          name: 'Camera',
          folder: const DeviceFolder('t', 'Camera', 'camera'),
          remote: const ['Backup'],
        );
        progress.reset();
        await expectLater(
          engine().run(account, wifiOnly),
          throwsA(isA<FormatException>()),
        );
        expect(server.uploads, 0);
      },
    );
  });

  group('progress', () {
    test('counts what is there, what is done, and what is left', () async {
      for (var i = 0; i < 10; i++) {
        device.add('f$i.jpg', bytes(i));
      }
      await run();
      expect(progress.found, 10);
      expect(progress.toUpload, 10);
      expect(progress.bytesTotal, 320);
      expect(progress.bytesDone, 320);
      expect(progress.remaining, 0);
      expect(progress.fraction, 1);
      device.add('new.jpg', bytes(99));
      await run();
      expect(progress.alreadyBackedUp, 10);
      expect(progress.toUpload, 1);
    });
  });
}
