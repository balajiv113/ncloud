import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/file_store.dart';
import 'package:ncloud/library_database.dart';
import 'package:ncloud/local_cache.dart';
import 'package:ncloud/models.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const library = 'library-v1|https://cloud.example|alice';
const listing = 'browse-v4|https://cloud.example|alice|0';

CloudFile photo(String path, {String? id, bool favorite = false}) => CloudFile(
  path: path.split('/'),
  name: path.split('/').last,
  isDirectory: false,
  contentType: 'image/jpeg',
  id: id,
  favorite: favorite,
  captureDay: 20454,
  etag: 'etag-$path',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LocalCache cache;
  String getPath() => '${root.path}/catalogue.sqlite3';

  setUp(() async {
    root = await Directory(
      '.dart_tool/library-db-tests/${DateTime.now().microsecondsSinceEpoch}/cache',
    ).absolute.create(recursive: true);
    cache = LocalCache(() async => root, databaseFactory: databaseFactoryFfi);
  });
  tearDown(() async {
    await cache.close();
    if (await root.parent.exists()) await root.parent.delete(recursive: true);
  });

  Future<Database> inspect() => databaseFactoryFfi.openDatabase(
    getPath(),
    options: OpenDatabaseOptions(singleInstance: false),
  );

  test(
    'files normalize by account and stable ID with queryable fields',
    () async {
      final first = photo('Photos/a.jpg', id: '7');
      final store = FileStore()
        ..putFolder(['Photos'], [first], etag: 'folder-v1');
      await cache.writeLibrary(library, store);
      await cache.writeListing(listing, [first, first]);
      await cache.writeListing('browse-v4|https://cloud.example|bob|0', [
        photo('Photos/a.jpg', id: '7', favorite: true),
      ]);
      await cache.writeListing('fallback', [photo('Photos/no-id.jpg')]);
      final db = await inspect();
      addTearDown(db.close);
      final rows = await db.query('files', orderBy: 'account');
      expect(rows, hasLength(3));
      final alice = rows.singleWhere(
        (row) => row['account'] == 'https://cloud.example|alice',
      );
      expect(alice['file_key'], 'id:7');
      expect(alice['content_type'], 'image/jpeg');
      expect(alice['capture_day'], 20454);
      expect(
        rows.singleWhere((row) => row['account'] == 'fallback')['file_key'],
        'path:Photos/no-id.jpg',
      );
      final collections = await db.query('collections');
      expect(
        collections.every(
          (row) => !(row['payload'] as String).contains('"files"'),
        ),
        isTrue,
      );
      expect(await cache.readListing(listing), hasLength(2));
      expect(
        (await cache.readFilesByIds(library, ['7'])).single.favorite,
        isFalse,
      );
      expect(
        (await cache.readFilesByIds('https://cloud.example|bob', [
          '7',
        ])).single.favorite,
        isTrue,
      );
      final restored = FileStore()
        ..clear()
        ..restore((await cache.readDocument(library))!);
      expect(restored.folder(['Photos'])!.single.id, '7');
      final folder = await cache.readFolderSnapshot(library, ['Photos']);
      expect(folder!.etag, 'folder-v1');
      expect(folder.files.single.id, '7');
    },
  );

  test(
    'ambiguous server IDs use path fallback without collapsing files',
    () async {
      final files = [
        photo('Photos/a.jpg', id: '7'),
        photo('Photos/b.jpg', id: '7'),
      ];
      final store = FileStore()..putAll(files);
      await cache.writeLibrary(library, store);
      await cache.writeListing(listing, files);
      final restored = FileStore()
        ..restore((await cache.readDocument(library))!);
      expect(restored.length, 2);
      expect((await cache.readListing(listing))!.map((file) => file.name), [
        'a.jpg',
        'b.jpg',
      ]);
      store.update(files.first.key, (file) => file.withFavorite(true));
      await cache.writeLibrary(library, store);
      expect((await cache.readListing(listing))!.first.favorite, isTrue);
      expect((await cache.readListing(listing))!.last.favorite, isFalse);
    },
  );

  test(
    'path fallback upgrades to stable identity and moves keep one record',
    () async {
      final first = photo('Photos/a.jpg');
      await cache.writeListing(listing, [first]);
      final store = FileStore()..putAll([photo('Photos/a.jpg', id: '7')]);
      await cache.writeLibrary(library, store);
      final db = await inspect();
      addTearDown(db.close);
      expect(await db.query('files'), hasLength(1));
      expect((await cache.readListing(listing))!.single.id, '7');
      store.moveTree(['Photos', 'a.jpg'], ['Archive', 'a.jpg']);
      await cache.writeLibrary(library, store);
      expect(await db.query('files'), hasLength(1));
      expect((await cache.readFilesByIds(library, ['7'])).single.path, [
        'Archive',
        'a.jpg',
      ]);
      final restored = FileStore()
        ..restore((await cache.readDocument(library))!);
      expect(restored.resolve(['Archive/a.jpg']), hasLength(1));
      expect(restored.resolve(['Photos/a.jpg']), isEmpty);
    },
  );

  test(
    'unchanged snapshots do not write and deltas update shared rows',
    () async {
      final first = photo('Photos/a.jpg', id: '7');
      final store = FileStore()..putAll([first]);
      await cache.writeLibrary(library, store);
      await cache.writeListing(listing, [first]);
      final db = await inspect();
      addTearDown(db.close);
      Future<int> version() async =>
          (await db.rawQuery('PRAGMA data_version')).single.values.single
              as int;
      final before = await version();
      await cache.writeLibrary(library, store);
      expect(await version(), before);
      store.update(first.key, (file) => file.withFavorite(true));
      await cache.writeLibrary(library, store);
      expect(await version(), greaterThan(before));
      expect((await cache.readListing(listing))!.single.favorite, isTrue);
      expect(await db.query('files'), hasLength(1));
      expect(store.persistenceChanges().files, isEmpty);
      await cache.close();
      cache = LocalCache(() async => root, databaseFactory: databaseFactoryFfi);
      expect(
        (await cache.readFilesByIds(library, ['7'])).single.favorite,
        isTrue,
      );
    },
  );

  test('acknowledgement never loses mutations made during a write', () {
    final first = photo('a.jpg', id: '1');
    final store = FileStore()..putAll([first]);
    final snapshot = store.persistenceChanges();
    store.update(first.key, (file) => file.withFavorite(true));
    store.acknowledgePersistence(snapshot);
    expect(store.persistenceChanges().files[first.key]!.favorite, isTrue);
    store.clear();
    store.putAll([photo('b.jpg', id: '2')]);
    final replacement = store.persistenceChanges();
    expect(replacement.replace, isTrue);
    expect(replacement.files.keys, ['b.jpg']);
  });

  test(
    'disk catalogue outlives RAM eviction and warm restore does not rewrite it',
    () async {
      final store = FileStore()
        ..putAll([
          for (var i = 0; i <= FileStore.maxFiles; i++)
            photo('Photos/$i.jpg', id: '$i'),
        ]);
      expect(store.length, FileStore.maxFiles);
      expect(store['Photos/0.jpg'], isNull);
      await cache.writeLibrary(library, store);
      expect((await cache.readFilesByIds(library, ['0'])).single.id, '0');
      expect(
        await cache.readDayFiles(library, [20454]),
        hasLength(FileStore.maxFiles),
      );
      final old = photo(
        'Photos/0.jpg',
        id: '0',
      ).withCaptureDate(DateTime.utc(2020), 'old', day: 18262);
      store.putAll([old]);
      await cache.writeLibrary(library, store);
      await cache.writeDocument(listing, {
        'keys': ['Photos/0.jpg'],
      });
      final restored = FileStore()
        ..clear()
        ..restore((await cache.readDocument(library))!);
      expect(restored.length, FileStore.maxFiles);
      expect(restored['Photos/0.jpg'], isNull);
      expect((await cache.readDayFiles(library, [18262])).single.id, '0');
      expect((await cache.readListing(listing))!.single.id, '0');
      final db = await inspect();
      addTearDown(db.close);
      final before = (await db.rawQuery('PRAGMA data_version')).single;
      await cache.writeLibrary(library, restored);
      expect((await db.rawQuery('PRAGMA data_version')).single, before);
      expect(await db.query('files', columns: ['file_key']), hasLength(40001));
      expect((await cache.readFilesByIds(library, ['0'])).single.id, '0');
      restored.putAll([photo('Photos/new.jpg', id: 'new')]);
      await cache.writeLibrary(library, restored);
      expect(
        await cache.readFilesByIds(library, ['0', '1', 'new']),
        hasLength(3),
      );
      restored.removeKeys(['Photos/0.jpg']);
      await cache.writeLibrary(library, restored);
      expect(await cache.readFilesByIds(library, ['0']), isEmpty);
      expect(await cache.readFilesByIds(library, ['1', 'new']), hasLength(2));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'day queries scope accounts, deduplicate days and order chunks stably',
    () async {
      final store = FileStore()
        ..putAll([
          for (var day = 0; day < 450; day++)
            photo(
              'Photos/$day.jpg',
              id: '$day',
            ).withCaptureDate(DateTime.utc(2026, 1, 1), 'day-$day', day: day),
        ]);
      await cache.writeLibrary(library, store);
      await cache.writeListing('browse-v4|https://cloud.example|bob|0', [
        photo(
          'Photos/bob.jpg',
          id: 'bob',
        ).withCaptureDate(DateTime.utc(2026), 'bob', day: 449),
      ]);
      expect(await cache.readDayFiles(library, []), isEmpty);
      expect(await cache.readDayFiles(library, [-1]), isEmpty);
      final files = await cache.readDayFiles('https://cloud.example|alice', [
        for (var day = 0; day < 450; day++) day,
        449,
        0,
      ]);
      expect(files, hasLength(450));
      expect(files.map((file) => file.captureDay), [
        for (var day = 449; day >= 0; day--) day,
      ]);
      expect(files.map((file) => file.id), isNot(contains('bob')));
      await cache.close();
      expect(
        (await cache.readDayFiles('https://cloud.example|bob', [
          449,
        ])).single.id,
        'bob',
      );
    },
  );

  test(
    'day freshness uses observation time, excluding native album members',
    () async {
      final old = photo('Photos/old.jpg', id: 'old');
      final store = FileStore()..putAll([old]);
      await cache.writeLibrary(library, store);
      final cutoff = DateTime.now();
      expect(
        await cache.readDayFiles(library, [20454], freshSince: cutoff),
        isEmpty,
      );
      final same = photo('Photos/old.jpg', id: 'old');
      final album = CloudFile(
        path: ['Albums', 'member.jpg'],
        name: 'member.jpg',
        isDirectory: false,
        contentType: 'image/jpeg',
        id: 'album',
        captureDay: 20454,
        albumDavPath: ['Albums', 'member.jpg'],
      );
      store.putAll([same, album]);
      await cache.writeLibrary(library, store);
      final fresh = await cache.readDayFiles(library, [
        20454,
      ], freshSince: cutoff);
      expect(fresh.map((file) => file.id), ['old']);
      await cache.close();
      final restored = FileStore()
        ..restore((await cache.readDocument(library))!);
      restored.markStale();
      await cache.writeLibrary(library, restored);
      expect(
        await cache.readDayFiles(library, [
          20454,
        ], freshSince: restored.staleBefore),
        isEmpty,
      );
      expect((await cache.readDayFiles(library, [20454])).single.id, 'old');
    },
  );

  test('legacy compressed library and plain listing migrate lazily', () async {
    final file = photo('Photos/a.jpg', id: '7');
    final store = FileStore()..putFolder(['Photos'], [file], etag: 'v1');
    final oldLibrary = File(
      '${root.path}/indexes/${cacheDigest(library)}.json',
    );
    final oldListing = File(
      '${root.path}/listings/${cacheDigest(listing)}.json',
    );
    await oldLibrary.parent.create(recursive: true);
    await oldListing.parent.create(recursive: true);
    await oldLibrary.writeAsBytes(
      gzip.encode(utf8.encode(jsonEncode(store.toJson()))),
    );
    await oldListing.writeAsString(jsonEncode([file.toJson()]));
    expect(await File(getPath()).exists(), isFalse);
    expect((await cache.readDocument(library))!['files'], hasLength(1));
    expect(await oldLibrary.exists(), isFalse);
    expect(await oldListing.exists(), isTrue);
    expect((await cache.readListing(listing))!.single.id, '7');
    expect(await oldListing.exists(), isFalse);
    final db = await inspect();
    addTearDown(db.close);
    expect(await db.query('files'), hasLength(1));
    expect(
      (await db.rawQuery('PRAGMA journal_mode')).single.values.single,
      'wal',
    );
    expect((await db.rawQuery('PRAGMA auto_vacuum')).single.values.single, 2);
  });

  test('schema version one migrates in place without losing records', () async {
    await cache.writeListing(listing, [photo('a.jpg', id: '7')]);
    await cache.close();
    final old = await inspect();
    await old.execute('DROP INDEX files_timeline');
    await old.execute('DROP INDEX files_type');
    await old.execute('PRAGMA user_version=1');
    await old.close();
    expect((await cache.readListing(listing))!.single.id, '7');
    final upgraded = await inspect();
    addTearDown(upgraded.close);
    expect(
      (await upgraded.rawQuery('PRAGMA user_version')).single.values.single,
      LibraryDatabase.schemaVersion,
    );
    final indexes = await upgraded.rawQuery('PRAGMA index_list(files)');
    expect(indexes.map((row) => row['name']), contains('files_timeline'));
  });

  test(
    'version two migration keeps old rows conservatively unobserved',
    () async {
      await cache.writeListing(listing, [photo('a.jpg', id: '7')]);
      await cache.close();
      final old = await inspect();
      await old.execute('ALTER TABLE files DROP COLUMN observed_at');
      await old.execute('PRAGMA user_version=2');
      await old.close();
      expect((await cache.readDayFiles(library, [20454])).single.id, '7');
      expect(
        await cache.readDayFiles(library, [
          20454,
        ], freshSince: DateTime.fromMillisecondsSinceEpoch(1)),
        isEmpty,
      );
      final store = FileStore()..putAll([photo('a.jpg', id: '7')]);
      await cache.writeLibrary(library, store);
      expect(
        (await cache.readDayFiles(library, [
          20454,
        ], freshSince: DateTime.fromMillisecondsSinceEpoch(1))).single.id,
        '7',
      );
    },
  );

  test(
    'persistent invalidation is account scoped and preserves originals',
    () async {
      final file = photo('Photos/a.jpg', id: '7');
      await cache.writeLibrary(
        library,
        FileStore()..putFolder(['Photos'], [file]),
      );
      await cache.writeDocument(listing, {
        'keys': [file.key],
        'updated': DateTime.now().toIso8601String(),
        'loaded': [20454],
      });
      await cache.writeDocument('people-v1|https://cloud.example|alice', {
        'ok': true,
      });
      await cache.writeDocument('browse-v4|https://cloud.example|bob|0', {
        'keys': <String>[],
      });
      final original = await cache.original('saved', 'a.jpg');
      await original.writeAsBytes([1, 2, 3]);
      await cache.writeOfflineListing('saved', [file]);
      await cache.invalidateListings(library);
      await cache.close();
      final stale = (await cache.readDocument(listing))!;
      expect(stale['keys'], [file.key]);
      expect(
        DateTime.parse(stale['updated'] as String).millisecondsSinceEpoch,
        0,
      );
      expect(stale['staleDays'], [20454]);
      final restored = FileStore()
        ..restore((await cache.readDocument(library))!);
      expect(restored.length, 1);
      expect(restored.folder(['Photos'], fresh: false), hasLength(1));
      expect(restored.folder(['Photos']), isNull);
      expect(restored.staleBefore.millisecondsSinceEpoch, greaterThan(0));
      expect(
        await cache.readDocument('people-v1|https://cloud.example|alice'),
        {'ok': true},
      );
      expect(
        await cache.readDocument('browse-v4|https://cloud.example|bob|0'),
        isNotNull,
      );
      expect(await original.readAsBytes(), [1, 2, 3]);
      expect(await cache.readOfflineListing('saved'), hasLength(1));
    },
  );

  test(
    'budget counts database, WAL, SHM and thumbnails using actual allocation',
    () async {
      cache = LocalCache(
        () async => root,
        databaseFactory: databaseFactoryFfi,
        budget: 256 * 1024,
      );
      final original = await cache.original('original', 'a.jpg');
      await original.writeAsBytes(Uint8List(500 * 1024));
      await cache.writeOfflineListing('offline', [photo('a.jpg')]);
      for (var i = 0; i < 10; i++) {
        await cache.writeDocument('doc-$i', {'value': '$i' * (60 * 1024)});
        expect(cache.writeError, isNull, reason: 'write $i');
        expect(await cache.size(), lessThanOrEqualTo(cache.budget));
      }
      await cache.writeThumbnail('preview', Uint8List(100 * 1024));
      var actual = 0;
      await for (final entity in root.list(recursive: true)) {
        if (entity is File) actual += await entity.length();
      }
      expect(await cache.size(), actual);
      expect(actual, lessThanOrEqualTo(cache.budget));
      expect(await original.length(), 500 * 1024);
      await cache.clear();
      expect(await cache.size(), 0);
      expect(await original.exists(), isTrue);
      expect(await cache.readOfflineListing('offline'), hasLength(1));
    },
  );

  test(
    'corrupt catalogue explicitly reports rebuild without touching downloads',
    () async {
      final file = photo('a.jpg', id: '7');
      final original = await cache.original('saved', 'a.jpg');
      await original.writeAsBytes([1, 2, 3]);
      await cache.writeOfflineListing('saved', [file]);
      await cache.writeListing(listing, [file]);
      await cache.close();
      await File(getPath()).writeAsBytes(utf8.encode('not a SQLite database'));
      String? warning;
      cache.onWriteError = (message) => warning = message;
      expect(await cache.readListing(listing), isNull);
      expect(warning, contains('rebuilt'));
      expect(await original.readAsBytes(), [1, 2, 3]);
      expect(await cache.readOfflineListing('saved'), hasLength(1));
      await cache.writeListing(listing, [file]);
      expect((await cache.readListing(listing))!.single.id, '7');
    },
  );

  test('restore bounds both file rows and folder membership memory', () {
    final value = photo('a.jpg').toJson();
    final restored = FileStore()
      ..restore({
        'files': [
          for (var i = 0; i <= FileStore.maxFiles; i++)
            {
              ...value,
              'path': ['$i.jpg'],
              'name': '$i.jpg',
            },
        ],
        'folders': {
          for (var i = 0; i <= FileStore.maxFolders; i++)
            '$i': {
              'children': <String>[],
              'updated': DateTime.now().toIso8601String(),
            },
        },
      });
    expect(restored.length, FileStore.maxFiles);
    expect(restored.toJson()['folders'], hasLength(FileStore.maxFolders));
  });
}
