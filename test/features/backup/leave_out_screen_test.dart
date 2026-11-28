import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/platform/album_folders.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:ncloud/features/backup/ui/backup_setup_screen.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' as fixtures;
import 'backup_controller_test.dart' show CloudFolders;
import 'folder_backup_screen_test.dart' show AvailableScheduler;

/// An iPhone with a few Photos albums.
class _Photos implements FolderAccess, PhotoAlbumAccess {
  @override
  Future<List<DeviceFolder>> albums() async => [
    DeviceFolder(
      cameraRollToken,
      'Camera Roll',
      'photos:ncloud.camera-roll',
      kind: DeviceSourceKind.photoAlbum,
    ),
    const DeviceFolder(
      'photos:w1',
      'W1',
      'photos:w1',
      kind: DeviceSourceKind.photoAlbum,
    ),
    const DeviceFolder(
      'photos:memes',
      'Memes',
      'photos:memes',
      kind: DeviceSourceKind.photoAlbum,
    ),
  ];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  Future<BackupController> open(WidgetTester tester, {FolderPair? pair}) async {
    final sync = BackupController(
      client: CloudFolders(),
      account: () => fixtures.account,
      access: _Photos(),
      android: false,
      ios: true,
      scheduler: AvailableScheduler(),
    );
    final app = AppController(
      store: MemoryStore(),
      client: CloudFolders(),
      backupController: sync,
    )..account = fixtures.account;
    addTearDown(app.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: BackupSetupScreen(controller: app, pair: pair),
      ),
    );
    await tester.pumpAndSettle();
    return sync;
  }

  FolderPair saved(DeviceFolder folder) => FolderPair(
    id: 'p',
    account: 'a|b',
    name: 'Camera Roll',
    folder: folder,
    remote: const ['Backup'],
  );

  testWidgets('a saved Camera Roll backup offers to leave albums out', (
    tester,
  ) async {
    await open(tester, pair: saved(cameraRollWith(const [])));
    expect(find.text('Albums in their own folders'), findsOneWidget);
    expect(find.text('Leave out albums'), findsOneWidget);
    expect(find.text('None'), findsOneWidget);
  });

  testWidgets('choosing albums to leave out shows them on the tile', (
    tester,
  ) async {
    await open(tester, pair: saved(cameraRollWith(const [])));
    await tester.ensureVisible(find.text('Leave out albums'));
    await tester.tap(find.text('Leave out albums'));
    await tester.pumpAndSettle();
    expect(find.text('W1'), findsOneWidget);
    expect(find.text('Memes'), findsOneWidget);
    await tester.tap(find.text('Memes'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();
    expect(find.text('Memes'), findsOneWidget);
    expect(find.text('None'), findsNothing);
  });

  testWidgets(
    'a backup that has album folders keeps them when leaving some out',
    (tester) async {
      const w1 = AlbumChoice('photos:w1', 'W1');
      await open(tester, pair: saved(cameraRollWith(const [w1])));
      await tester.ensureVisible(find.text('Leave out albums'));
      await tester.tap(find.text('Leave out albums'));
      await tester.pumpAndSettle();
      expect(
        find.widgetWithText(CheckboxListTile, 'W1'),
        findsNothing,
        reason: 'already in its own folder',
      );
      await tester.tap(find.text('Memes'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('W1'), findsOneWidget);
      expect(find.text('Memes'), findsOneWidget);
    },
  );
}
