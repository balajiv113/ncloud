import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/folder_sync.dart';
import 'package:ncloud/features/backup/folder_sync_screen.dart';
import 'package:ncloud/features/backup/sync_rules.dart';
import 'package:ncloud/features/backup/sync_schedule.dart';

import '../../app_test.dart' show MemoryStore;
import 'folder_sync_test.dart' show CloudFolders;
import '../../nextcloud_client_test.dart' as fixtures;

class PickerAccess implements FolderAccess, PhotoAlbumAccess {
  int folderPicks = 0, albumLists = 0;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
  @override
  Future<DeviceFolder?> pick() async {
    folderPicks++;
    return const DeviceFolder('folder', 'Camera', 'folder');
  }

  @override
  Future<List<DeviceFolder>> albums() async {
    albumLists++;
    return const [
      DeviceFolder(
        'album',
        'Travel',
        'album',
        kind: DeviceSourceKind.photoAlbum,
      ),
    ];
  }
}

class BrowsingCloud extends CloudFolders {}

class MemoryBackupController extends FolderSyncController {
  MemoryBackupController({required PickerAccess picker, bool ios = false})
    : super(
        client: CloudFolders(),
        account: () => fixtures.account,
        access: picker,
        android: !ios,
        ios: ios,
        scheduler: AvailableScheduler(),
      );
  int singleRuns = 0, batchRuns = 0;
  bool failSchedule = false;
  @override
  Future<void> load() async {}
  @override
  Future<void> refreshResults() async {}
  @override
  Future<void> run(FolderPair pair, {bool headless = false}) async {
    singleRuns++;
  }

  @override
  Future<void> runAll() async {
    batchRuns++;
  }

  @override
  Future<void> add(
    String name,
    DeviceFolder folder,
    List<String> remote, {
    bool wifiOnly = true,
    SyncRules rules = const SyncRules.all(),
    int uploadConcurrency = 1,
    FolderPair? replacing,
    BackupSchedule? schedule,
  }) async {
    if (replacing == null && pairs.isNotEmpty) {
      throw const FormatException('Pair already exists');
    }
    pairs = [
      FolderPair(
        id: replacing?.id ?? 'new',
        account: syncAccount(account()!),
        name: name,
        folder: folder,
        remote: remote,
        rules: rules,
        wifiOnly: wifiOnly,
        schedule: schedule,
      ),
    ];
    notifyListeners();
    if (failSchedule) {
      throw BackupScheduleFailure(pairs.single, 'Scheduling failed');
    }
  }

  @override
  Future<void> forget(FolderPair pair) async {
    pairs.removeWhere((p) => p.id == pair.id);
    notifyListeners();
  }
}

class AvailableScheduler extends UnsupportedBackupScheduler {
  @override
  bool get supported => true;
}

FolderPair savedPair(String name) => FolderPair(
  id: name,
  account: syncAccount(fixtures.account),
  name: name,
  folder: DeviceFolder(name, name, name),
  remote: const ['Backup'],
);

void main() {
  late PickerAccess picker;
  late MemoryBackupController sync;
  late AppController app;

  void setup({bool ios = false}) {
    picker = PickerAccess();
    sync = MemoryBackupController(picker: picker, ios: ios);
    app = AppController(
      store: MemoryStore(),
      client: BrowsingCloud(),
      folderSyncController: sync,
    )..account = fixtures.account;
  }

  tearDown(() => app.dispose());

  testWidgets('compact cards expose individual and all backup actions', (
    tester,
  ) async {
    setup();
    sync.pairs = [savedPair('Camera'), savedPair('Travel')];
    await tester.pumpWidget(
      MaterialApp(home: FolderSyncScreen(controller: app)),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSize(find.byType(Card).first).height,
      lessThanOrEqualTo(150),
    );
    await tester.tap(find.text('Back up').first);
    await tester.pump();
    expect(sync.singleRuns, 1);
    await tester.tap(find.text('Back up all'));
    await tester.pump();
    expect(sync.batchRuns, 1);
    expect(find.text('Continue in background'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Android setup saves patterns and removes without confirmation', (
    tester,
  ) async {
    setup();
    final pair = savedPair('Documents');
    sync.pairs = [pair];
    await tester.pumpWidget(
      MaterialApp(home: FolderSyncScreen(controller: app)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Edit Documents'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Device folder'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '*.jpg, *.mp4');
    await tester.enterText(find.byType(TextField).at(1), '*.tmp');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(picker.folderPicks, 1);
    expect(picker.albumLists, 0);
    expect(sync.pairs.single.rules.include, ['*.jpg', '*.mp4']);
    expect(sync.pairs.single.rules.exclude, ['*.tmp']);
    expect(find.byType(AlertDialog), findsNothing);
    await tester.tap(find.byTooltip('Edit Camera'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Remove backup'));
    await tester.tap(find.text('Remove backup'));
    await tester.pumpAndSettle();
    expect(sync.pairs, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('iOS selects albums and has no charging or cron options', (
    tester,
  ) async {
    setup(ios: true);
    await tester.pumpWidget(
      MaterialApp(
        home: BackupSetupScreen(controller: app, pair: savedPair('Old')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Device folder'), findsNothing);
    await tester.tap(find.text('Photos album'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Travel'));
    await tester.pumpAndSettle();
    expect(picker.albumLists, 1);
    expect(picker.folderPicks, 0);
    expect(find.text('Only while charging'), findsNothing);
    expect(find.text('Cron'), findsNothing);
    expect(find.text('Transfer direction'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a saved new pair can retry scheduling without adding a duplicate',
    (tester) async {
      setup();
      sync.failSchedule = true;
      await tester.pumpWidget(
        MaterialApp(home: BackupSetupScreen(controller: app)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Device folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cloud destination'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Use this folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('Edit backup'), findsOneWidget);
      expect(sync.pairs, hasLength(1));
      sync.failSchedule = false;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(sync.pairs, hasLength(1));
      await tester.pumpWidget(const SizedBox());
    },
  );
}
