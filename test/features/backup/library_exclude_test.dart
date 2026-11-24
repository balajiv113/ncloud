import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/engine/sync_runner.dart';
import 'package:ncloud/features/backup/model/sync_rules.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/platform/sync_run_lock.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:ncloud/features/backup/ui/backup_setup_screen.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' as fixtures;
import '../../support/backup_fakes.dart';
import 'backup_controller_test.dart' show CloudFolders;
import 'folder_backup_screen_test.dart' show AvailableScheduler;

LibraryItem item(int id, String folder, {String? name}) => LibraryItem(
  id: 'image:$id',
  name: name ?? 'IMG_$id.jpg',
  size: 4,
  modified: 1700000000000 + id,
  contentType: 'image/jpeg',
  folder: folder,
);

class _Library {
  final items = <String, Map<String, Object?>>{};
  final contents = <String, List<int>>{};
  late Directory staging;
  int next = 1;

  void add(String folder, List<int> bytes) {
    final id = 'image:${next++}';
    items[id] = {
      'id': id,
      'name': 'IMG_${next - 1}.jpg',
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

  group('the source', () {
    test('without folders left out it is the plain library', () {
      final plain = DeviceFolder.library();
      expect(plain.token, DeviceFolder.libraryToken);
      expect(DeviceFolder.excludedFolders(plain.token), isEmpty);
      expect(DeviceFolder.isLibraryToken(plain.token), isTrue);
    });

    test('folders left out are kept, and the backup keeps its identity', () {
      final folder = DeviceFolder.library(
        excluded: [
          ['Pictures', 'Screenshots'],
          ['DCIM', 'Memes'],
        ],
      );
      expect(DeviceFolder.isLibraryToken(folder.token), isTrue);
      expect(DeviceFolder.excludedFolders(folder.token), [
        ['Pictures', 'Screenshots'],
        ['DCIM', 'Memes'],
      ]);
      expect(folder.identity, DeviceFolder.library().identity);
      expect(folder.name, 'Phone');
      expect(folder.kind, DeviceSourceKind.library);
    });

    test('other sources are not the library', () {
      expect(DeviceFolder.isLibraryToken('content://tree/x'), isFalse);
      expect(DeviceFolder.excludedFolders('content://tree/x'), isEmpty);
    });
  });

  group('the tree', () {
    final items = [
      item(1, 'DCIM/Camera/'),
      item(2, 'Pictures/Camera/'),
      item(3, 'Pictures/Screenshots/'),
      item(4, 'Pictures/Screenshots/'),
      item(5, 'DCIM/Memes/'),
    ];

    List<String> names(LibraryTree tree) => [
      for (final e in tree.children(const [])) e.name,
    ];

    test('lists every folder with how many files it holds', () {
      final folders = LibraryTree(items).folders;
      expect(
        {for (final f in folders) f.name: f.files},
        {'Camera': 1, 'Camera (Pictures)': 1, 'Screenshots': 2, 'Memes': 1},
      );
      expect(folders.firstWhere((f) => f.name == 'Screenshots').path, [
        'Pictures',
        'Screenshots',
      ]);
    });

    test('a folder left out is not listed', () {
      final tree = LibraryTree(
        items,
        exclude: [
          ['Pictures', 'Screenshots'],
        ],
      );
      expect(names(tree), ['Camera', 'Camera (Pictures)', 'Memes']);
    });

    test('leaving one out never renames another', () {
      final all = names(LibraryTree(items));
      final without = names(
        LibraryTree(
          items,
          exclude: [
            ['DCIM', 'Camera'],
          ],
        ),
      );
      // The other Camera folder keeps the name it already had on the server.
      expect(all, contains('Camera (Pictures)'));
      expect(without, contains('Camera (Pictures)'));
      expect(without, isNot(contains('Camera')));
    });

    test('a folder left out takes the folders inside it too', () {
      final tree = LibraryTree(
        [item(1, 'Pictures/Trips/'), item(2, 'Pictures/Trips/Rome/')],
        exclude: [
          ['Pictures', 'Trips'],
        ],
      );
      expect(names(tree), isEmpty);
    });
  });

  group('backing up with folders left out', () {
    late Directory root;
    late _Library library;
    late FakeServer server;
    late SyncJournal journal;
    late NativeFolderAccess access;

    FolderPair pair(DeviceFolder folder) => FolderPair(
      id: 'lib',
      account: syncAccount(fixtures.account),
      name: 'All photos & videos',
      folder: folder,
      remote: const ['Backup'],
      wifiOnly: false,
    );

    Future<SyncProgress> run(FolderPair value) async {
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
      await journal.save(value);
      await runner.run(fixtures.account, value);
      expect(runner.error, isNull);
      return progress;
    }

    setUp(() async {
      root = await Directory.systemTemp.createTemp('exclude');
      library = _Library()
        ..staging = await Directory('${root.path}/s').create();
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

    test('a folder left out is not uploaded, the rest is', () async {
      library.add('DCIM/Camera/', [1, 2, 3, 4]);
      library.add('Pictures/Screenshots/', [5, 6, 7, 8]);
      library.add('DCIM/Memes/', [9, 9, 9, 9]);
      final progress = await run(
        pair(
          DeviceFolder.library(
            excluded: [
              ['Pictures', 'Screenshots'],
              ['DCIM', 'Memes'],
            ],
          ),
        ),
      );
      expect(server.files.keys, ['Backup/Phone/Camera/IMG_1.jpg']);
      expect(progress.found, 1);
    });

    test(
      'leaving a folder out later keeps what is already on the server',
      () async {
        library.add('DCIM/Camera/', [1, 2, 3, 4]);
        library.add('Pictures/Screenshots/', [5, 6, 7, 8]);
        await run(pair(DeviceFolder.library()));
        expect(server.files, hasLength(2));
        await run(
          pair(
            DeviceFolder.library(
              excluded: [
                ['Pictures', 'Screenshots'],
              ],
            ),
          ),
        );
        expect(server.files, hasLength(2));
        expect(server.uploads, 2);
      },
    );

    test('bringing a folder back uploads it', () async {
      library.add('DCIM/Camera/', [1, 2, 3, 4]);
      library.add('Pictures/Screenshots/', [5, 6, 7, 8]);
      final left = DeviceFolder.library(
        excluded: [
          ['Pictures', 'Screenshots'],
        ],
      );
      await run(pair(left));
      expect(server.files, hasLength(1));
      await run(pair(DeviceFolder.library()));
      expect(server.files, hasLength(2));
    });

    test('the folders to choose from include those already left out', () async {
      library.add('DCIM/Camera/', [1, 2, 3, 4]);
      library.add('Pictures/Screenshots/', [5, 6, 7, 8]);
      library.add('Pictures/Screenshots/', [5, 6, 7, 9]);
      final folders = await access.libraryFolders();
      expect(
        {for (final f in folders) f.name: f.files},
        {'Camera': 1, 'Screenshots': 2},
      );
    });
  });

  group('the setup screen', () {
    late Directory root;
    late _Library library;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('screen');
      library = _Library()
        ..staging = await Directory('${root.path}/s').create();
      messenger.setMockMethodCallHandler(
        NativeFolderAccess.channel,
        library.handle,
      );
    });
    tearDown(() async {
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null);
      await root.delete(recursive: true);
    });

    Future<void> open(WidgetTester tester, FolderPair? pair) async {
      final sync = BackupController(
        client: CloudFolders(),
        account: () => fixtures.account,
        access: NativeFolderAccess(),
        android: true,
        ios: false,
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
    }

    FolderPair saved({SyncRules rules = const SyncRules.all()}) => FolderPair(
      id: 'p',
      account: 'a|b',
      name: 'All photos & videos',
      folder: DeviceFolder.library(),
      remote: const ['Backup'],
      rules: rules,
    );

    testWidgets(
      'offers folders to leave out with their sizes, and no patterns',
      (tester) async {
        library.add('DCIM/Camera/', [1, 2, 3, 4]);
        library.add('Pictures/Screenshots/', [5, 6, 7, 8]);
        library.add('Pictures/Screenshots/', [5, 6, 7, 9]);
        await open(tester, saved());
        expect(find.text('Include patterns'), findsNothing);
        expect(find.text('Exclude patterns'), findsNothing);
        expect(find.text('Leave out folders'), findsOneWidget);
        await tester.ensureVisible(find.text('Leave out folders'));
        await tester.tap(find.text('Leave out folders'));
        await tester.pumpAndSettle();
        expect(find.text('Camera'), findsOneWidget);
        expect(find.text('1 file'), findsOneWidget);
        expect(find.text('Screenshots'), findsOneWidget);
        expect(find.text('2 files'), findsOneWidget);
        await tester.tap(find.text('Screenshots'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('Screenshots'), findsOneWidget);
        expect(find.text('None'), findsNothing);
      },
    );

    testWidgets(
      'folders already left out show ticked and can be brought back',
      (tester) async {
        library.add('DCIM/Camera/', [1, 2, 3, 4]);
        library.add('Pictures/Screenshots/', [5, 6, 7, 8]);
        await open(
          tester,
          FolderPair(
            id: 'p',
            account: 'a|b',
            name: 'All photos & videos',
            folder: DeviceFolder.library(
              excluded: [
                ['Pictures', 'Screenshots'],
              ],
            ),
            remote: const ['Backup'],
          ),
        );
        await tester.ensureVisible(find.text('Leave out folders'));
        await tester.tap(find.text('Leave out folders'));
        await tester.pumpAndSettle();
        final ticked = tester.widget<CheckboxListTile>(
          find.widgetWithText(CheckboxListTile, 'Screenshots'),
        );
        expect(ticked.value, isTrue);
        await tester.tap(find.widgetWithText(CheckboxListTile, 'Screenshots'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Done'));
        await tester.pumpAndSettle();
        expect(find.text('None'), findsOneWidget);
      },
    );

    testWidgets('patterns an older backup already has stay visible', (
      tester,
    ) async {
      await open(
        tester,
        saved(rules: SyncRules.patterns('', 'Screenshots/**')),
      );
      expect(find.text('Exclude patterns'), findsOneWidget);
    });
  });
}
