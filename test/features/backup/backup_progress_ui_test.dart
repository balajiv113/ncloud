import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:ncloud/features/backup/ui/backup_status.dart';
import 'package:ncloud/features/backup/ui/folder_backup_screen.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' as fixtures;
import 'backup_controller_test.dart' show CloudFolders;
import 'folder_backup_screen_test.dart' show AvailableScheduler;

class _Access implements FolderAccess {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _Backup extends BackupController {
  _Backup()
    : super(
        client: CloudFolders(),
        account: () => fixtures.account,
        access: _Access(),
        android: true,
        ios: false,
        scheduler: AvailableScheduler(),
      );

  List<StoredFailure> stored = [];
  int retries = 0;
  int again = 0;

  @override
  Future<void> load() async {}
  @override
  Future<void> refreshResults() async {}
  @override
  Future<List<StoredFailure>> failures(FolderPair pair) async => stored;
  @override
  Future<void> retryFailed(FolderPair pair) async => retries++;
  @override
  Future<void> backUpAgain(FolderPair pair) async => again++;
}

FolderPair pair() => FolderPair(
  id: 'p',
  account: syncAccount(fixtures.account),
  name: 'Camera',
  folder: const DeviceFolder('t', 'Camera', 'camera'),
  remote: const ['Backup'],
);

void main() {
  group('formatting', () {
    test('counts get thousands separators', () {
      expect(formatCount(0), '0');
      expect(formatCount(999), '999');
      expect(formatCount(1000), '1,000');
      expect(formatCount(12431), '12,431');
      expect(formatCount(1234567), '1,234,567');
    });

    test('time left is said the way a person would say it', () {
      expect(
        formatRemaining(const Duration(seconds: 20)),
        'less than a minute left',
      );
      expect(formatRemaining(const Duration(minutes: 12)), 'about 12 min left');
      expect(
        formatRemaining(const Duration(hours: 2, minutes: 10)),
        'about 2 h left',
      );
      expect(formatRemaining(const Duration(days: 3)), 'about 3 days left');
    });

    test('sizes use the right unit', () {
      expect(formatSize(512), '512 B');
      expect(formatSize(2048), '2.0 KB');
      expect(formatSize(5 * 1024 * 1024), '5.0 MB');
      expect(formatSize(3 * 1024 * 1024 * 1024), '3.0 GB');
    });
  });

  group('BackupNumbers', () {
    test('describe a run in progress', () {
      final progress = SyncProgress()
        ..found = 12460
        ..toUpload = 12460
        ..bytesTotal = 1000
        ..transferred = 3204;
      final numbers = BackupNumbers.fromProgress(progress);
      expect(numbers.progressLine, '3,204 of 12,460');
      expect(numbers.percent, isNotNull);
      expect(numbers.problemLine, isNull);
    });

    test('summarise a finished run and name the problems', () {
      final numbers = BackupNumbers.fromState({
        'found': 12460,
        'toUpload': 100,
        'transferred': 71,
        'failed': 29,
      });
      expect(numbers.summaryLine, '12,431 of 12,460 backed up');
      expect(numbers.problemLine, '29 files could not be backed up');
      expect(numbers.fraction, 1);
    });

    test('a clean run says so, and one problem is singular', () {
      expect(BackupNumbers.fromState({'found': 5}).summaryLine, '5 backed up');
      expect(
        BackupNumbers.fromState({'found': 5, 'blocked': 1}).problemLine,
        '1 file could not be backed up',
      );
    });

    test('files waiting for a retry count as problems', () {
      final numbers = BackupNumbers.fromState({
        'found': 10,
        'failed': 1,
        'blocked': 2,
      });
      expect(numbers.problems, 3);
      expect(numbers.backedUp, 7);
    });

    test('nothing is claimed before there is anything to say', () {
      final numbers = BackupNumbers.fromState(null);
      expect(numbers.summaryLine, isNull);
      expect(numbers.progressLine, isNull);
      expect(numbers.percent, isNull);
    });
  });

  group('the backup card', () {
    late _Backup sync;

    Future<void> show(WidgetTester tester) async {
      final controller = AppController(
        store: MemoryStore(),
        client: CloudFolders(),
        backupController: sync,
      )..account = fixtures.account;
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(home: FolderBackupScreen(controller: controller)),
      );
      // A running backup animates its bar forever, so wait a fixed moment.
      await tester.pump(const Duration(milliseconds: 200));
    }

    setUp(() {
      sync = _Backup()..pairs = [pair()];
    });

    testWidgets('shows live progress, the file in hand and time left', (
      tester,
    ) async {
      sync.activeId = 'p';
      sync.progress
        ..found = 12460
        ..toUpload = 12460
        ..bytesTotal = 1000000
        ..current = 'IMG_2031.jpg'
        ..transferred = 3204
        ..bytesDone = 250000
        ..failed = 2;
      await show(tester);
      expect(find.textContaining('3,206 of 12,460'), findsWidgets);
      expect(find.text('Uploading IMG_2031.jpg'), findsOneWidget);
      expect(
        find.textContaining('2 files could not be backed up so far'),
        findsOneWidget,
      );
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNotNull);
      expect(find.text('Pause'), findsOneWidget);
    });

    testWidgets('before the count is known the bar just moves', (tester) async {
      sync.activeId = 'p';
      sync.progress.phase = 'Reading selected device folder';
      await show(tester);
      expect(find.text('Reading selected device folder'), findsOneWidget);
      final bar = tester.widget<LinearProgressIndicator>(
        find.byType(LinearProgressIndicator),
      );
      expect(bar.value, isNull);
    });

    testWidgets('a clean run says how much is backed up', (tester) async {
      sync.results['p'] = {'status': 'success', 'found': 12460, 'toUpload': 0};
      await show(tester);
      expect(find.text('12,460 backed up'), findsOneWidget);
      expect(find.textContaining('could not be backed up'), findsNothing);
      expect(find.text('Back up'), findsOneWidget);
    });

    testWidgets('problems are named, explained in a list, and can be retried', (
      tester,
    ) async {
      sync.results['p'] = {
        'status': 'partial',
        'found': 12460,
        'toUpload': 100,
        'transferred': 71,
        'failed': 29,
      };
      sync.stored = [
        StoredFailure(
          path: const ['2024', 'IMG_9.jpg'],
          version: 'v',
          message: 'Could not read this file.',
          attempts: 3,
          at: DateTime(2025),
        ),
      ];
      await show(tester);
      expect(find.text('12,431 of 12,460 backed up'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.textContaining('see why'));
      await tester.pumpAndSettle();
      expect(find.text('Could not be backed up'), findsOneWidget);
      expect(find.text('2024/IMG_9.jpg'), findsOneWidget);
      expect(find.textContaining('Could not read this file.'), findsOneWidget);
      expect(find.textContaining('tried 3 times'), findsOneWidget);
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(sync.retries, 1);
    });

    testWidgets('Back up again asks first, then checks everything', (
      tester,
    ) async {
      sync.results['p'] = {'status': 'success', 'found': 10};
      await show(tester);
      await tester.tap(find.byTooltip('More for Camera'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back up again'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('recognised and not uploaded twice'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sync.again, 0);
      await tester.tap(find.byTooltip('More for Camera'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Back up again'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Back up again'));
      await tester.pumpAndSettle();
      expect(sync.again, 1);
    });

    testWidgets('files moved on the server are mentioned', (tester) async {
      sync.results['p'] = {'status': 'success', 'found': 100, 'moved': 12};
      await show(tester);
      expect(
        find.text('100 backed up · 12 moved on your server'),
        findsOneWidget,
      );
    });

    testWidgets('a failed run shows its reason and offers Retry', (
      tester,
    ) async {
      sync.results['p'] = {
        'status': 'error',
        'error': 'Your server storage is full.',
      };
      await show(tester);
      expect(find.text('Your server storage is full.'), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
    });
  });
}
