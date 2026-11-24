import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/sync_runner.dart';
import 'package:ncloud/features/backup/platform/album_folders.dart';
import 'package:ncloud/features/backup/platform/sync_run_lock.dart';
import 'package:ncloud/features/backup/state/backup_controller.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../../nextcloud_client_test.dart' as fixtures;
import '../../support/backup_fakes.dart';

String albumToken(String id) => 'photos:${base64Encode(utf8.encode(id))}';

/// The iPhone's Photos, answering the native calls: every photo is in the
/// library, and some are in albums too.
class _Photos {
  final assets = <String, ({List<int> bytes, Set<String> albums})>{};
  final missingAlbums = <String>{};
  final failingAlbums = <String>{};
  late Directory staging;
  var modified = 1700000000000;

  void add(String name, List<int> bytes, {Set<String> albums = const {}}) =>
      assets[name] = (bytes: bytes, albums: albums);

  void putIn(String name, String album) => assets[name] = (
    bytes: assets[name]!.bytes,
    albums: {...assets[name]!.albums, album},
  );

  void takeOut(String name, String album) => assets[name] = (
    bytes: assets[name]!.bytes,
    albums: {...assets[name]!.albums}..remove(album),
  );

  Map<String, Object?> _entry(String name) => {
    'name': name,
    'directory': false,
    'size': -1,
    'modified': modified,
    'contentType': 'image/heic',
    'revision': 'r-$name',
  };

  Future<Object?> handle(MethodCall call) async {
    final args = call.arguments as Map<dynamic, dynamic>? ?? {};
    switch (call.method) {
      case 'list':
        final token = args['token'] as String;
        if (token == cameraRollToken) {
          return [for (final name in assets.keys) _entry(name)];
        }
        final id = utf8.decode(base64Decode(token.substring(7)));
        if (missingAlbums.contains(id)) {
          throw PlatformException(code: 'photos_album', message: 'gone');
        }
        if (failingAlbums.contains(id)) {
          throw PlatformException(code: 'photos_permission', message: 'no');
        }
        return [
          for (final MapEntry(key: name, value: asset) in assets.entries)
            if (asset.albums.contains(id)) _entry(name),
        ];
      case 'export':
        final name = (args['path'] as List).single as String;
        final file = File('${staging.path}/$name.part');
        await file.writeAsBytes(assets[name]!.bytes);
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

  group('the token', () {
    test('round-trips the albums in order', () {
      final folder = cameraRollWith([
        AlbumChoice(albumToken('a'), 'W1'),
        AlbumChoice(albumToken('b'), 'Trips'),
      ]);
      expect(isCameraRoll(folder.token), isTrue);
      expect(
        [for (final a in albumsOf(folder.token)!) a.name],
        ['W1', 'Trips'],
      );
      expect(folder.name, 'Camera Roll');
    });

    test('keeps the identity, so the backup and its records survive', () {
      expect(
        cameraRollWith([AlbumChoice(albumToken('a'), 'W1')]).identity,
        cameraRollWith(const []).identity,
      );
    });

    test('albums to leave out are kept in the token, beside the folders', () {
      final folder = cameraRollWith(
        [AlbumChoice(albumToken('a'), 'W1')],
        exclude: [
          AlbumChoice(albumToken('b'), 'Hidden stuff'),
          AlbumChoice(albumToken('c'), 'Memes'),
        ],
      );
      expect([for (final a in albumsOf(folder.token)!) a.name], ['W1']);
      expect(
        [for (final a in excludedOf(folder.token)) a.name],
        ['Hidden stuff', 'Memes'],
      );
      expect(folder.identity, cameraRollWith(const []).identity);
    });

    test('leaving albums out alone still makes a combined token', () {
      final folder = cameraRollWith(
        const [],
        exclude: [AlbumChoice(albumToken('b'), 'Memes')],
      );
      expect(folder.token, isNot(cameraRollToken));
      expect(isCameraRoll(folder.token), isTrue);
      expect(albumsOf(folder.token), isEmpty);
      expect(excludedOf(folder.token), hasLength(1));
    });

    test('a token from before albums could be left out still reads', () {
      final old =
          'photoset:${base64Url.encode(utf8.encode(jsonEncode([
            [albumToken('a'), 'W1'],
          ])))}';
      expect([for (final a in albumsOf(old)!) a.name], ['W1']);
      expect(excludedOf(old), isEmpty);
    });

    test('no albums is the plain library; other tokens are not it', () {
      expect(excludedOf(cameraRollToken), isEmpty);
      expect(cameraRollWith(const []).token, cameraRollToken);
      expect(albumsOf(cameraRollToken), isEmpty);
      expect(albumsOf(albumToken('a')), isNull);
      expect(isCameraRoll('library:all'), isFalse);
    });
  });

  group('the tree', () {
    DeviceEntryList files(List<String> names) => [
      for (final n in names) DeviceEntry(n, false, -1, 1, revision: 'r'),
    ];

    test('gives each photo to the first album that holds it', () {
      final tree = AlbumFolderTree(
        [AlbumChoice('t1', 'A'), AlbumChoice('t2', 'B')],
        [
          files(['x', 'y']),
          files(['y', 'z']),
        ],
        files(['x', 'y', 'z', 'w']),
      );
      expect(
        [for (final e in tree.children(const [])) e.name],
        ['A', 'B', 'w'],
      );
      expect(
        [
          for (final e in tree.children(['A'])) e.name,
        ],
        ['x', 'y'],
      );
      expect(
        [
          for (final e in tree.children(['B'])) e.name,
        ],
        ['z'],
      );
      expect(tree.tokenFor(['B', 'z']), 't2');
      expect(tree.tokenFor(['w']), isNull);
    });

    test('photos in an excluded album are dropped everywhere', () {
      final tree = AlbumFolderTree(
        [AlbumChoice('t1', 'A')],
        [
          files(['x', 'y']),
        ],
        files(['x', 'y', 'z', 'w']),
        excluded: [
          files(['y', 'w']),
        ],
      );
      expect([for (final e in tree.children(const [])) e.name], ['A', 'z']);
      expect(
        [
          for (final e in tree.children(['A'])) e.name,
        ],
        ['x'],
      );
    });

    test('an empty album makes no folder', () {
      final tree = AlbumFolderTree(
        [AlbumChoice('t1', 'A')],
        [files([])],
        files(['w']),
      );
      expect([for (final e in tree.children(const [])) e.name], ['w']);
    });

    test('albums with one name get distinct folders', () {
      final tree = AlbumFolderTree(
        [AlbumChoice('t1', 'Trip'), AlbumChoice('t2', 'Trip')],
        [
          files(['x']),
          files(['y']),
        ],
        files(['x', 'y']),
      );
      expect(
        [for (final e in tree.children(const [])) e.name],
        ['Trip', 'Trip (2)'],
      );
    });
  });

  group('backing up the library with album folders', () {
    late Directory root;
    late _Photos photos;
    late FakeServer server;
    late SyncJournal journal;
    late NativeFolderAccess access;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final w1 = AlbumChoice(albumToken('w1'), 'W1');

    FolderPair pairWith(List<AlbumChoice> albums) => FolderPair(
      id: 'cr',
      account: syncAccount(fixtures.account),
      name: 'Camera Roll',
      folder: cameraRollWith(albums),
      remote: const ['Backup'],
      wifiOnly: false,
    );

    Future<SyncProgress> run(FolderPair pair) async {
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
      await journal.save(pair);
      await runner.run(fixtures.account, pair);
      expect(runner.error, isNull);
      return progress;
    }

    List<int> bytes(int i) => [i, i + 1, i + 2, 9, 9, 9];

    setUp(() async {
      root = await Directory.systemTemp.createTemp('albums');
      photos = _Photos()..staging = await Directory('${root.path}/s').create();
      server = FakeServer();
      journal = SyncJournal(
        path: '${root.path}/j.db',
        factory: databaseFactoryFfi,
      );
      access = NativeFolderAccess();
      messenger.setMockMethodCallHandler(
        NativeFolderAccess.channel,
        photos.handle,
      );
    });
    tearDown(() async {
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null);
      await journal.close();
      await root.delete(recursive: true);
    });

    test(
      'each photo is stored once, album photos in their own folder',
      () async {
        photos.add('a.heic', bytes(1), albums: {'w1'});
        photos.add('b.heic', bytes(2), albums: {'w1'});
        photos.add('c.heic', bytes(3));
        photos.add('d.heic', bytes(4));
        final progress = await run(pairWith([w1]));
        expect(server.files.keys.toSet(), {
          'Backup/Camera Roll/W1/a.heic',
          'Backup/Camera Roll/W1/b.heic',
          'Backup/Camera Roll/c.heic',
          'Backup/Camera Roll/d.heic',
        });
        expect(progress.transferred, 4);
        expect(server.uploads, 4);
      },
    );

    test('a photo put into an album moves on the server, no upload', () async {
      photos.add('a.heic', bytes(1));
      photos.add('b.heic', bytes(2));
      await run(pairWith([w1]));
      expect(server.files.keys, contains('Backup/Camera Roll/a.heic'));
      photos.putIn('a.heic', 'w1');
      final progress = await run(pairWith([w1]));
      expect(server.uploads, 2);
      expect(server.moves, 1);
      expect(progress.moved, 1);
      expect(server.files.keys.toSet(), {
        'Backup/Camera Roll/W1/a.heic',
        'Backup/Camera Roll/b.heic',
      });
    });

    test('a photo taken out of an album goes back to the top', () async {
      photos.add('a.heic', bytes(1), albums: {'w1'});
      await run(pairWith([w1]));
      photos.takeOut('a.heic', 'w1');
      await run(pairWith([w1]));
      expect(server.uploads, 1);
      expect(server.files.keys, ['Backup/Camera Roll/a.heic']);
    });

    test('choosing an album later moves what is already backed up', () async {
      photos.add('a.heic', bytes(1), albums: {'w1'});
      photos.add('b.heic', bytes(2));
      await run(pairWith(const []));
      expect(server.files.keys.toSet(), {
        'Backup/Camera Roll/a.heic',
        'Backup/Camera Roll/b.heic',
      });
      await run(pairWith([w1]));
      expect(server.uploads, 2);
      expect(server.files.keys.toSet(), {
        'Backup/Camera Roll/W1/a.heic',
        'Backup/Camera Roll/b.heic',
      });
    });

    test('a repeat run finds nothing to do', () async {
      photos.add('a.heic', bytes(1), albums: {'w1'});
      photos.add('b.heic', bytes(2));
      await run(pairWith([w1]));
      final again = await run(pairWith([w1]));
      expect(server.uploads, 2);
      expect(again.toUpload, 0);
      expect(again.alreadyBackedUp, 2);
    });

    test('an album deleted on the phone does not stop the backup', () async {
      photos.add('a.heic', bytes(1), albums: {'w1'});
      photos.missingAlbums.add('w1');
      await run(pairWith([w1]));
      expect(server.files.keys, ['Backup/Camera Roll/a.heic']);
    });

    test('photos in an excluded album are not uploaded', () async {
      final memes = AlbumChoice(albumToken('memes'), 'Memes');
      photos.add('a.heic', bytes(1), albums: {'memes'});
      photos.add('b.heic', bytes(2), albums: {'w1'});
      photos.add('c.heic', bytes(3));
      photos.add('d.heic', bytes(4), albums: {'w1', 'memes'});
      final progress = await run(
        FolderPair(
          id: 'cr',
          account: syncAccount(fixtures.account),
          name: 'Camera Roll',
          folder: cameraRollWith([w1], exclude: [memes]),
          remote: const ['Backup'],
          wifiOnly: false,
        ),
      );
      expect(server.files.keys.toSet(), {
        'Backup/Camera Roll/W1/b.heic',
        'Backup/Camera Roll/c.heic',
      });
      expect(progress.found, 2);
    });

    test(
      'leaving an album out later does not touch what is on the server',
      () async {
        final memes = AlbumChoice(albumToken('memes'), 'Memes');
        photos.add('a.heic', bytes(1), albums: {'memes'});
        photos.add('c.heic', bytes(3));
        await run(pairWith(const []));
        expect(server.files, hasLength(2));
        await run(
          FolderPair(
            id: 'cr',
            account: syncAccount(fixtures.account),
            name: 'Camera Roll',
            folder: cameraRollWith(const [], exclude: [memes]),
            remote: const ['Backup'],
            wifiOnly: false,
          ),
        );
        expect(server.files, hasLength(2));
        expect(server.uploads, 2);
      },
    );

    test(
      'an excluded album that cannot be read stops the run, uploading nothing',
      () async {
        final memes = AlbumChoice(albumToken('memes'), 'Memes');
        photos.add('a.heic', bytes(1), albums: {'memes'});
        photos.failingAlbums.add('memes');
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
        final pair = FolderPair(
          id: 'cr',
          account: syncAccount(fixtures.account),
          name: 'Camera Roll',
          folder: cameraRollWith(const [], exclude: [memes]),
          remote: const ['Backup'],
          wifiOnly: false,
        );
        await journal.save(pair);
        await runner.run(fixtures.account, pair);
        expect(runner.error, isNotNull);
        expect(server.uploads, 0);
      },
    );

    test(
      'an excluded album deleted on the phone does not stop the backup',
      () async {
        final memes = AlbumChoice(albumToken('memes'), 'Memes');
        photos.add('a.heic', bytes(1));
        photos.missingAlbums.add('memes');
        await run(
          FolderPair(
            id: 'cr',
            account: syncAccount(fixtures.account),
            name: 'Camera Roll',
            folder: cameraRollWith(const [], exclude: [memes]),
            remote: const ['Backup'],
            wifiOnly: false,
          ),
        );
        expect(server.files.keys, ['Backup/Camera Roll/a.heic']);
      },
    );

    test('a photo in two albums is stored once, in the first', () async {
      final trips = AlbumChoice(albumToken('trips'), 'Trips');
      photos.add('a.heic', bytes(1), albums: {'w1', 'trips'});
      await run(pairWith([trips, w1]));
      expect(server.files.keys, ['Backup/Camera Roll/Trips/a.heic']);
      expect(server.uploads, 1);
    });
  });
}

typedef DeviceEntryList = List<DeviceEntry>;
