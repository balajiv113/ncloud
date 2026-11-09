import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/backup/engine/conflict_name.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/backup/engine/pair_policy.dart';
import 'package:ncloud/features/backup/engine/sync_engine.dart';
import 'package:ncloud/features/backup/engine/sync_errors.dart';
import 'package:ncloud/features/backup/state/sync_journal.dart';
import 'package:ncloud/features/backup/model/backup_schedule.dart';
import 'package:ncloud/models.dart';

String message(Object error, {String phase = 'Uploading a.jpg'}) =>
    describeSyncError(error, phase: phase).message;

void main() {
  group('describeSyncError', () {
    test('uses the message of errors written for the user', () {
      expect(message(const CloudException('Quota exceeded')), 'Quota exceeded');
      expect(message(StateError('Reconnect first.')), 'Reconnect first.');
      expect(
        message(const FormatException('Use 1 to 3 uploads.')),
        'Use 1 to 3 uploads.',
      );
    });

    test('explains a missing native service as a restart problem', () {
      expect(message(MissingPluginException('x')), contains('fully restart'));
    });

    test('maps platform codes to actions and keeps the code', () {
      final denied = describeSyncError(
        PlatformException(code: 'folder_permission'),
        phase: 'x',
      );
      expect(denied.message, contains('Reselect the source'));
      expect(denied.code, 'folder_permission');
      expect(
        message(PlatformException(code: 'photos_album', message: 'Album gone')),
        'Album gone',
      );
      expect(
        message(PlatformException(code: 'photos_album')),
        contains('Photos album backup needs attention (photos_album)'),
      );
      expect(
        message(PlatformException(code: 'background_permission')),
        contains('Allow ncloud notifications'),
      );
      expect(message(PlatformException(code: 'odd')), contains('failed (odd)'));
    });

    test('names transient failures without leaking details', () {
      expect(
        message(const FileSystemException('/private/path')),
        isNot(contains('/private/path')),
      );
      expect(message(const SocketException('host')), contains('interrupted'));
      expect(message(TimeoutException('slow')), contains('timed out'));
      final unknown = message(ArgumentError('x'), phase: 'Reading cloud');
      expect(unknown, contains('ArgumentError'));
      expect(unknown, contains('Reading cloud'));
      expect(describeSyncError(ArgumentError('x'), phase: 'p').code, isNull);
    });
  });

  group('conflictName', () {
    String tag() => 'abc123';

    test('keeps the folder and extension and marks the new copy', () {
      expect(conflictName(['2024', 'photo.jpg'], 'device', suffix: tag), [
        '2024',
        'photo (ncloud device abc123).jpg',
      ]);
    });

    test('handles names without an extension and dotfiles', () {
      expect(conflictName(['notes'], 'device', suffix: tag), [
        'notes (ncloud device abc123)',
      ]);
      expect(conflictName(['.env'], 'cloud', suffix: tag), [
        '.env (ncloud cloud abc123)',
      ]);
    });

    test('shortens a long stem by bytes and rejects a long extension', () {
      final long = '${'é' * 100}.jpg';
      final shortened = conflictName([long], 'device', suffix: tag).single;
      expect(shortened.endsWith(' (ncloud device abc123).jpg'), isTrue);
      expect(shortened.split(' (ncloud').first.length, lessThanOrEqualTo(70));
      expect(
        () => conflictName(['a.${'x' * 40}'], 'device', suffix: tag),
        throwsFormatException,
      );
    });

    test('random suffixes differ between calls', () {
      expect(
        conflictName(['a.txt'], 'device'),
        isNot(conflictName(['a.txt'], 'device')),
      );
    });
  });

  group('validatePair', () {
    const camera = DeviceFolder('t1', 'Camera', 'camera');
    FolderPair pair(String id, DeviceFolder folder, List<String> remote) =>
        FolderPair(
          id: id,
          account: 'a|b',
          name: folder.name,
          folder: folder,
          remote: remote,
        );

    void validate({
      DeviceFolder folder = camera,
      List<String> remote = const ['Backup'],
      int concurrency = 1,
      BackupSchedule? schedule,
      bool schedulerSupported = true,
      bool ios = false,
      Iterable<FolderPair> existing = const [],
      FolderPair? replacing,
    }) => validatePair(
      folder: folder,
      remote: remote,
      uploadConcurrency: concurrency,
      schedule: schedule,
      schedulerSupported: schedulerSupported,
      ios: ios,
      existing: existing,
      replacing: replacing,
    );

    test('accepts an ordinary pair', validate);

    test('limits uploads to one to three at a time', () {
      expect(() => validate(concurrency: 0), throwsFormatException);
      expect(() => validate(concurrency: 4), throwsFormatException);
      validate(concurrency: 3);
    });

    test('Photos albums and iOS background backups are iOS-only', () {
      const album = DeviceFolder(
        'p',
        'Trip',
        'trip',
        kind: DeviceSourceKind.photoAlbum,
      );
      expect(() => validate(folder: album), throwsFormatException);
      validate(folder: album, ios: true);
      final daily = BackupSchedule(created: DateTime(2024));
      expect(
        () => validate(folder: camera, ios: true, schedule: daily),
        throwsFormatException,
      );
      validate(folder: album, ios: true, schedule: daily);
    });

    test('schedules need a scheduler', () {
      final daily = BackupSchedule(created: DateTime(2024));
      expect(
        () => validate(schedule: daily, schedulerSupported: false),
        throwsFormatException,
      );
    });

    test(
      'rejects an already used device folder or overlapping cloud folders',
      () {
        final first = pair('1', camera, ['Backup']);
        expect(() => validate(existing: [first]), throwsFormatException);
        const other = DeviceFolder('t2', 'Downloads', 'downloads');
        expect(
          () => validate(
            folder: other,
            remote: const ['Backup', 'Camera'],
            existing: [first],
          ),
          throwsFormatException,
        );
        expect(
          () => validate(folder: other, remote: const [], existing: [first]),
          returnsNormally,
        );
        validate(folder: other, remote: const ['Other'], existing: [first]);
      },
    );

    test('a pair being edited does not conflict with itself', () {
      final first = pair('1', camera, ['Backup']);
      validate(existing: [first], replacing: first);
    });
  });

  group('remoteVersion', () {
    test('combines the server revision with the size', () {
      const file = CloudFile(
        path: ['a'],
        name: 'a',
        isDirectory: false,
        size: 12,
        etag: 'abc',
      );
      expect(remoteVersion(file), 'abc|12');
    });

    test('refuses a file the server gave no revision for', () {
      const file = CloudFile(path: ['a'], name: 'a', isDirectory: false);
      expect(() => remoteVersion(file), throwsFormatException);
    });
  });

  group('runConcurrently', () {
    test('never runs more than the allowed number at once', () async {
      var running = 0;
      var peak = 0;
      final done = <int>[];
      await runConcurrently(List.generate(8, (i) => i), 3, (item) async {
        peak = peak < ++running ? running : peak;
        await Future<void>.delayed(const Duration(milliseconds: 5));
        running--;
        done.add(item);
      });
      expect(peak, 3);
      expect(done..sort(), List.generate(8, (i) => i));
    });

    test('stops starting work after a failure and rethrows it', () async {
      final started = <int>[];
      await expectLater(
        runConcurrently(List.generate(6, (i) => i), 1, (item) async {
          started.add(item);
          if (item == 2) throw StateError('boom');
        }),
        throwsStateError,
      );
      expect(started, [0, 1, 2]);
    });

    test('a real failure outranks a stop requested at the same time', () async {
      await expectLater(
        runConcurrently([0, 1], 2, (item) async {
          if (item == 0) throw SyncStopped();
          await Future<void>.delayed(const Duration(milliseconds: 5));
          throw StateError('real');
        }),
        throwsStateError,
      );
    });
  });

  group('FolderPair.dueSlot', () {
    final created = DateTime(2024, 1, 1);
    FolderPair scheduled({String revision = 'r1', BackupSchedule? schedule}) =>
        FolderPair(
          id: 'p',
          account: 'a|b',
          name: 'Camera',
          folder: const DeviceFolder('t', 'Camera', 'camera'),
          remote: const ['Backup'],
          revision: revision,
          schedule: schedule ?? BackupSchedule(created: created),
        );
    final afterTwo = DateTime(2024, 3, 10, 3);

    test('is the latest occurrence when nothing ran yet', () {
      expect(scheduled().dueSlot({}, afterTwo), '2024-03-10');
    });

    test('is nothing before the first occurrence or without a schedule', () {
      expect(scheduled().dueSlot({}, DateTime(2024, 1, 1, 1)), isNull);
      final plain = FolderPair(
        id: 'p',
        account: 'a|b',
        name: 'Camera',
        folder: const DeviceFolder('t', 'Camera', 'camera'),
        remote: const ['Backup'],
      );
      expect(plain.dueSlot({}, afterTwo), isNull);
    });

    test('is nothing once that occurrence ran for this revision', () {
      final state = {'revision': 'r1', 'slot': '2024-03-10'};
      expect(scheduled().dueSlot(state, afterTwo), isNull);
      expect(
        scheduled().dueSlot({'revision': 'r1', 'slot': '2024-03-09'}, afterTwo),
        '2024-03-10',
      );
    });

    test('an edited pair runs again even if the slot was handled before', () {
      final state = {'revision': 'old', 'slot': '2024-03-10'};
      expect(scheduled(revision: 'new').dueSlot(state, afterTwo), '2024-03-10');
    });
  });

  group('BackupSchedule.forTime', () {
    test('keeps the creation time when only other settings changed', () {
      final previous = BackupSchedule(created: DateTime(2024, 1, 1), hour: 2);
      final edited = BackupSchedule.forTime(
        2,
        0,
        previous: previous,
        now: DateTime(2024, 6, 1),
      );
      expect(edited.created, DateTime(2024, 1, 1));
    });

    test('starts fresh when the time changed or there was no schedule', () {
      final previous = BackupSchedule(created: DateTime(2024, 1, 1), hour: 2);
      final now = DateTime(2024, 6, 1);
      expect(
        BackupSchedule.forTime(3, 30, previous: previous, now: now).created,
        now,
      );
      expect(BackupSchedule.forTime(2, 0, now: now).created, now);
    });
  });

  test('only unreachable sources ask the user to pick again', () {
    for (final code in [
      'folder_permission',
      'photos_permission',
      'photos_album',
    ]) {
      expect(sourceNeedsReselect(code), isTrue);
    }
    expect(sourceNeedsReselect('folder_io'), isFalse);
    expect(sourceNeedsReselect(null), isFalse);
  });

  group('describeLoadError', () {
    String load(Object error) =>
        describeLoadError(error, operation: 'read saved folder settings');

    test('says what was attempted and that the user can retry', () {
      final text = load(const FormatException('Bad settings.'));
      expect(text, startsWith('Could not read saved folder settings.'));
      expect(text, contains('Bad settings.'));
      expect(text, endsWith('Retry loading folder settings.'));
    });

    test('points at a restart when the native service is missing', () {
      expect(
        load(MissingPluginException('x')),
        contains('install the latest build'),
      );
    });

    test('uses the iOS message for a refused schedule and codes otherwise', () {
      expect(
        load(
          PlatformException(
            code: 'backup_schedule',
            message: 'Allow Background App Refresh.',
          ),
        ),
        contains('Allow Background App Refresh.'),
      );
      expect(
        load(PlatformException(code: 'other')),
        contains('Device service error (other)'),
      );
      expect(load(ArgumentError('x')), contains('ArgumentError'));
    });
  });
}
