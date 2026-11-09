import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/pair_policy.dart';
import 'package:ncloud/features/backup/model/folder_pair.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';

LibraryItem item(
  int id,
  String name,
  String folder, {
  String kind = 'image',
  int size = 10,
  int modified = 1700000000000,
}) => LibraryItem(
  id: '$kind:$id',
  name: name,
  size: size,
  modified: modified,
  contentType: kind == 'image' ? 'image/jpeg' : 'video/mp4',
  folder: folder,
);

List<String> names(List<DeviceEntry> entries) => [
  for (final e in entries) e.name,
];

void main() {
  group('LibraryTree', () {
    test('shows album folders by the phone\'s own name, with no hierarchy', () {
      final tree = LibraryTree([
        item(1, 'IMG_1.jpg', 'DCIM/Camera/'),
        item(2, 'shot.png', 'Pictures/Screenshots/'),
        item(
          3,
          'chat.jpg',
          'Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/',
        ),
      ]);
      final top = tree.children([]);
      expect(names(top), ['Camera', 'Screenshots', 'WhatsApp Images']);
      expect(top.every((e) => e.directory), isTrue);
      expect(names(tree.children(['Camera'])), ['IMG_1.jpg']);
      expect(tree.children(['Camera', 'deeper']), isEmpty);
    });

    test('a file carries the details the engine needs', () {
      final tree = LibraryTree([
        item(
          7,
          'clip.mp4',
          'DCIM/Camera',
          kind: 'video',
          size: 999,
          modified: 5,
        ),
      ]);
      final entry = tree.children(['Camera']).single;
      expect(entry.directory, isFalse);
      expect(entry.size, 999);
      expect(entry.modified, 5);
      expect(entry.contentType, 'video/mp4');
      expect(entry.id, 'video:7');
      expect(tree.file(['Camera', 'clip.mp4'])!.id, 'video:7');
      expect(tree.file(['Camera', 'missing.mp4']), isNull);
      expect(tree.file(['Camera']), isNull);
    });

    test('two folders with one name stay apart, the same way every time', () {
      final items = [
        item(1, 'a.jpg', 'Pictures/Camera'),
        item(2, 'b.jpg', 'DCIM/Camera'),
      ];
      final forward = LibraryTree(items);
      final backward = LibraryTree(items.reversed);
      expect(names(forward.children([])), ['Camera', 'Camera (Pictures)']);
      expect(names(backward.children([])), names(forward.children([])));
      // DCIM sorts first, so it keeps the plain name in both.
      expect(forward.file(['Camera', 'b.jpg']), isNotNull);
      expect(forward.file(['Camera (Pictures)', 'a.jpg']), isNotNull);
    });

    test('files in the top of storage go to Other', () {
      final tree = LibraryTree([item(1, 'x.jpg', '')]);
      expect(names(tree.children([])), ['Other']);
    });

    test(
      'files with one name keep it for the lowest id and add the id for the rest',
      () {
        final tree = LibraryTree([
          item(30, 'IMG.jpg', 'DCIM/Camera'),
          item(10, 'IMG.jpg', 'DCIM/Camera'),
          item(20, 'IMG', 'DCIM/Camera'),
          item(25, 'IMG', 'DCIM/Camera'),
        ]);
        expect(names(tree.children(['Camera'])).toSet(), {
          'IMG.jpg',
          'IMG-30.jpg',
          'IMG',
          'IMG-25',
        });
        expect(tree.file(['Camera', 'IMG.jpg'])!.id, 'image:10');
      },
    );

    test('a name never changes when more files arrive later', () {
      final before = LibraryTree([item(10, 'IMG.jpg', 'DCIM/Camera')]);
      final after = LibraryTree([
        item(10, 'IMG.jpg', 'DCIM/Camera'),
        item(40, 'IMG.jpg', 'DCIM/Camera'),
        item(5000, 'IMG.jpg', 'DCIM/Camera'),
      ]);
      expect(before.file(['Camera', 'IMG.jpg'])!.id, 'image:10');
      expect(after.file(['Camera', 'IMG.jpg'])!.id, 'image:10');
    });

    test('odd characters become safe names', () {
      final tree = LibraryTree([
        item(1, 'a/b\\c.jpg', 'Pictures/My: "Trip"'),
        item(2, '', 'DCIM/Camera'),
        item(3, '..', 'DCIM/Camera'),
      ]);
      for (final folder in tree.children([])) {
        expect(folder.name, isNot(contains('/')));
        for (final file in tree.children([folder.name])) {
          expect(
            () => checkSyncPath([folder.name, file.name]),
            returnsNormally,
          );
        }
      }
      expect(tree.file(['My: "Trip"', 'a_b_c.jpg']), isNotNull);
    });

    test('leaves out folders it was told to skip, and what is inside them', () {
      final tree = LibraryTree(
        [
          item(1, 'a.jpg', 'DCIM/Camera'),
          item(2, 'b.jpg', 'DCIM/Camera/Burst'),
          item(3, 'c.jpg', 'Pictures/Screenshots'),
          item(4, 'd.jpg', 'DCIM/CameraOld'),
        ],
        exclude: [
          ['DCIM', 'Camera'],
        ],
      );
      expect(names(tree.children([])), ['CameraOld', 'Screenshots']);
    });

    test('an empty library is an empty list, not an error', () {
      expect(LibraryTree(const []).children([]), isEmpty);
    });
  });

  group('the native bridge', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    late List<MethodCall> calls;
    var status = 'granted';
    var total = 0;

    setUp(() {
      calls = [];
      status = 'granted';
      total = 0;
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        calls.add(call);
        switch (call.method) {
          case 'mediaAccess':
            return {'status': status};
          case 'mediaRequest':
            status = 'granted';
            return {'status': status};
          case 'mediaList':
            final offset = call.arguments['offset'] as int;
            final limit = call.arguments['limit'] as int;
            return [
              for (var i = offset; i < total && i < offset + limit; i++)
                {
                  'id': 'image:$i',
                  'name': 'IMG_$i.jpg',
                  'size': 10,
                  'modified': 1700000000000 + i,
                  'contentType': 'image/jpeg',
                  'folder': 'DCIM/Camera/',
                },
            ];
          case 'mediaExport':
            return '/tmp/staged-${call.arguments['id']}.part';
        }
        return null;
      });
    });
    tearDown(
      () =>
          messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null),
    );

    test('reads a huge library a page at a time', () async {
      total = 4500;
      final access = NativeFolderAccess();
      final top = await access.list(DeviceFolder.libraryToken, []);
      expect(names(top), ['Camera']);
      final files = await access.list(DeviceFolder.libraryToken, ['Camera']);
      expect(files, hasLength(4500));
      final pages = calls.where((c) => c.method == 'mediaList').toList();
      expect(pages.map((c) => c.arguments['offset']), [0, 2000, 4000]);
      expect(pages.every((c) => c.arguments['limit'] == 2000), isTrue);
    });

    test('looks at the phone once per run, not once per folder', () async {
      total = 3;
      final access = NativeFolderAccess();
      await access.list(DeviceFolder.libraryToken, []);
      await access.list(DeviceFolder.libraryToken, ['Camera']);
      await access.list(DeviceFolder.libraryToken, ['Camera']);
      expect(calls.where((c) => c.method == 'mediaList'), hasLength(1));
      await access.list(DeviceFolder.libraryToken, []);
      expect(calls.where((c) => c.method == 'mediaList'), hasLength(2));
    });

    test('exports by the id the listing gave', () async {
      total = 2;
      final access = NativeFolderAccess();
      await access.list(DeviceFolder.libraryToken, []);
      final entries = await access.list(DeviceFolder.libraryToken, ['Camera']);
      final file = await access.export(DeviceFolder.libraryToken, [
        'Camera',
        entries.first.name,
      ], entries.first);
      expect(file.path, '/tmp/staged-image:0.part');
      final call = calls.lastWhere((c) => c.method == 'mediaExport');
      expect(call.arguments['id'], 'image:0');
      expect(call.arguments['size'], 10);
    });

    test(
      'refuses when access was taken away, with a code the engine stops on',
      () async {
        status = 'denied';
        await expectLater(
          NativeFolderAccess().list(DeviceFolder.libraryToken, []),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'media_permission',
            ),
          ),
        );
      },
    );

    test('still lists what it may see when access is partial', () async {
      status = 'partial';
      total = 2;
      final access = NativeFolderAccess();
      expect(await access.libraryPermission(), LibraryPermission.partial);
      expect(names(await access.list(DeviceFolder.libraryToken, [])), [
        'Camera',
      ]);
      expect(
        await access.list(DeviceFolder.libraryToken, ['Camera']),
        hasLength(2),
      );
    });

    test('asks for permission only when told to', () async {
      status = 'denied';
      final access = NativeFolderAccess();
      expect(await access.libraryPermission(), LibraryPermission.denied);
      expect(calls.where((c) => c.method == 'mediaRequest'), isEmpty);
      expect(
        await access.requestLibraryPermission(),
        LibraryPermission.granted,
      );
    });

    test('leaves out the folders it was told to skip', () async {
      total = 2;
      final access = NativeFolderAccess()
        ..skipFolders([
          ['DCIM', 'Camera'],
        ]);
      expect(await access.list(DeviceFolder.libraryToken, []), isEmpty);
    });
  });

  group('pair rules', () {
    FolderPair pair(String id, DeviceFolder folder) => FolderPair(
      id: id,
      account: 'a|b',
      name: folder.name,
      folder: folder,
      remote: const ['Backup'],
    );

    test('the whole library is a source of its own, on Android only', () {
      const library = DeviceFolder.library();
      expect(library.kind, DeviceSourceKind.library);
      void validate({required bool ios}) => validatePair(
        folder: library,
        remote: const ['Backup'],
        uploadConcurrency: 1,
        schedule: null,
        schedulerSupported: true,
        ios: ios,
        existing: const [],
      );
      validate(ios: false);
      expect(() => validate(ios: true), throwsFormatException);
    });

    test('folders already backed up by another backup are skipped', () {
      final library = pair('lib', const DeviceFolder.library());
      final camera = pair(
        'a',
        const DeviceFolder(
          'content://com.android.externalstorage.documents/tree/primary%3ADCIM%2FCamera',
          'Camera',
          'x',
        ),
      );
      final sd = pair(
        'b',
        const DeviceFolder(
          'content://com.android.externalstorage.documents/tree/1234-ABCD%3AMusic',
          'Music',
          'y',
        ),
      );
      final downloads = pair(
        'c',
        const DeviceFolder(
          'content://com.android.providers.downloads.documents/tree/downloads',
          'Downloads',
          'z',
        ),
      );
      expect(coveredFolders(library, [library, camera, sd, downloads]), [
        ['DCIM', 'Camera'],
      ]);
    });

    test('only the whole-library backup skips anything', () {
      final camera = pair(
        'a',
        const DeviceFolder(
          'content://x/tree/primary%3ADCIM%2FCamera',
          'Camera',
          'x',
        ),
      );
      expect(coveredFolders(camera, [camera]), isEmpty);
    });

    test('a backup of main storage root covers nothing it cannot name', () {
      final library = pair('lib', const DeviceFolder.library());
      final root = pair(
        'a',
        const DeviceFolder('content://x/tree/primary%3A', 'Phone', 'x'),
      );
      expect(coveredFolders(library, [root]), isEmpty);
    });
  });
}
