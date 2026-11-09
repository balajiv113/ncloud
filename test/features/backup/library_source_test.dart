import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:ncloud/features/backup/ui/backup_setup_screen.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' as fixtures;
import 'backup_controller_test.dart' show CloudFolders;
import 'folder_backup_screen_test.dart' show AvailableScheduler;

/// A phone that can read its photo library and says what it may read.
class _Phone implements FolderAccess, LibraryAccess {
  _Phone(this.permission, {this.grantsWhenAsked = LibraryPermission.granted});

  LibraryPermission permission;
  final LibraryPermission grantsWhenAsked;
  int asked = 0;
  int folderPicks = 0;

  @override
  Future<LibraryPermission> libraryPermission() async => permission;

  @override
  Future<LibraryPermission> requestLibraryPermission() async {
    asked++;
    return permission = grantsWhenAsked;
  }

  @override
  void skipFolders(List<List<String>> folders) {}

  @override
  Future<DeviceFolder?> pick() async {
    folderPicks++;
    return const DeviceFolder('folder', 'Documents', 'folder');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _Plain implements FolderAccess {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

BackupController controller(FolderAccess access) => BackupController(
  client: CloudFolders(),
  account: () => fixtures.account,
  access: access,
  android: true,
  ios: false,
  scheduler: AvailableScheduler(),
);

void main() {
  group('choosing the whole library', () {
    test('is offered with the library as its source', () async {
      final sync = controller(_Phone(LibraryPermission.granted));
      final folder = await sync.chooseLibrary();
      expect(folder.kind, DeviceSourceKind.library);
      expect(folder.token, DeviceFolder.libraryToken);
    });

    test('asks for access only when it does not have it', () async {
      final have = _Phone(LibraryPermission.granted);
      await controller(have).chooseLibrary();
      expect(have.asked, 0);
      final need = _Phone(LibraryPermission.denied);
      await controller(need).chooseLibrary();
      expect(need.asked, 1);
    });

    test(
      'limited access is accepted, since some photos are better than none',
      () async {
        final phone = _Phone(LibraryPermission.partial);
        expect(
          (await controller(phone).chooseLibrary()).kind,
          DeviceSourceKind.library,
        );
        expect(phone.asked, 0);
      },
    );

    test('refusing access says why and what to do', () async {
      final phone = _Phone(
        LibraryPermission.denied,
        grantsWhenAsked: LibraryPermission.denied,
      );
      await expectLater(
        controller(phone).chooseLibrary(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('settings'),
          ),
        ),
      );
    });

    test('is not available where the phone cannot read a library', () async {
      final sync = controller(_Plain());
      expect(await sync.libraryPermission(), isNull);
      await expectLater(sync.chooseLibrary(), throwsFormatException);
    });
  });

  group('the setup screen', () {
    Future<_Phone> open(
      WidgetTester tester,
      LibraryPermission permission,
    ) async {
      final phone = _Phone(permission);
      final sync = controller(phone);
      final app = AppController(
        store: MemoryStore(),
        client: CloudFolders(),
        backupController: sync,
      )..account = fixtures.account;
      addTearDown(app.dispose);
      await tester.pumpWidget(
        MaterialApp(home: BackupSetupScreen(controller: app)),
      );
      await tester.pumpAndSettle();
      return phone;
    }

    testWidgets('offers all photos and videos beside a single folder', (
      tester,
    ) async {
      await open(tester, LibraryPermission.granted);
      await tester.tap(find.text('What to back up'));
      await tester.pumpAndSettle();
      expect(find.text('All photos & videos'), findsOneWidget);
      expect(find.text('A folder'), findsOneWidget);
      expect(find.textContaining('by its own folders'), findsOneWidget);
      await tester.tap(find.text('All photos & videos'));
      await tester.pumpAndSettle();
      expect(find.text('All photos & videos'), findsOneWidget);
      expect(find.textContaining('Only some of your photos'), findsNothing);
    });

    testWidgets('limited access is explained under the source', (tester) async {
      await open(tester, LibraryPermission.partial);
      await tester.tap(find.text('What to back up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All photos & videos'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Only some of your photos are visible'),
        findsOneWidget,
      );
    });

    testWidgets('a single folder still works', (tester) async {
      final phone = await open(tester, LibraryPermission.granted);
      await tester.tap(find.text('What to back up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('A folder'));
      await tester.pumpAndSettle();
      expect(phone.folderPicks, 1);
      expect(find.text('Documents'), findsOneWidget);
    });

    testWidgets('closing the choice picks nothing', (tester) async {
      final phone = await open(tester, LibraryPermission.granted);
      await tester.tap(find.text('What to back up'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(phone.folderPicks, 0);
      expect(find.text('Choose source'), findsOneWidget);
    });
  });
}
