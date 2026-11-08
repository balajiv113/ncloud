import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/main.dart';
import 'package:ncloud/models.dart';

import '../app_test.dart' show MemoryStore;
import '../nextcloud_client_test.dart' show account;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGOQqMgGAAGnAPzLMdOkAAAAAElFTkSuQmCC',
);

/// A small photo library with Travel and Family albums, a favorite or two and
/// some documents, kept in memory behind [CloudBackend] so UI and controller
/// tests can browse, edit and refresh it like a real server.
List<CloudFile> sampleFiles() {
  final now = DateTime.now();
  var nextId = 100;
  CloudFile folder(List<String> path) => CloudFile(
    path: path,
    name: path.last,
    isDirectory: true,
    id: '${nextId++}',
  );
  return [
    folder(['Photos']),
    for (final path in [
      ['Photos', 'Travel'],
      ['Photos', 'Travel', 'Japan'],
      ['Photos', 'Travel', 'Japan', 'Kyoto'],
      ['Photos', 'Travel', 'Italy'],
      ['Photos', 'Travel', 'Italy', 'Dolomites'],
      ['Photos', 'Family'],
      ['Photos', 'Family', 'Coast & country'],
      ['Photos', 'Empty folder'],
      ['Weekend escapes'],
      ['Coast & country'],
      ['Documents'],
    ])
      folder(path),
    CloudFile(
      path: const ['Welcome to ncloud.txt'],
      name: 'Welcome to ncloud.txt',
      isDirectory: false,
      contentType: 'text/plain',
      size: 1280,
      modified: now,
      favorite: true,
      id: '${nextId++}',
    ),
    CloudFile(
      path: const ['Documents', 'Travel notes.pdf'],
      name: 'Travel notes.pdf',
      isDirectory: false,
      contentType: 'application/pdf',
      size: 281600,
      modified: now.subtract(const Duration(days: 3)),
      id: '${nextId++}',
    ),
    for (final (index, name) in [
      'Alpine morning',
      'Desert light',
      'Ocean breeze',
      'After the rain',
      'Golden hour',
      'Into the blue',
      'Quiet places',
      'Weekend escape',
      'City sunset',
      'The long way home',
      'First light',
      'Wild coast',
    ].indexed)
      CloudFile(
        path: [
          'Photos',
          if (index < 8) ...[
            'Travel',
            index < 4 ? 'Japan' : 'Italy',
            index < 4 ? 'Kyoto' : 'Dolomites',
          ] else ...[
            'Family',
            'Coast & country',
          ],
          '$name.${index == 11 ? 'mp4' : 'jpg'}',
        ],
        name: '$name.${index == 11 ? 'mp4' : 'jpg'}',
        isDirectory: false,
        contentType: index == 11 ? 'video/mp4' : 'image/jpeg',
        size: 2100000 + index * 190000,
        modified: now.subtract(
          Duration(days: index < 4 ? index ~/ 2 : index * 6),
        ),
        favorite: index == 0 || index == 4 || index == 8,
        id: '${nextId++}',
      ),
  ];
}

/// An in-memory cloud account for tests. It has no Memories-style day index,
/// so the library browses through folders and paged search like a plain
/// WebDAV server.
class SampleLibrary implements CloudBackend {
  SampleLibrary({List<CloudFile>? files}) : files = files ?? sampleFiles();

  final List<CloudFile> files;
  final Map<String, List<CloudFile>> _trash = {};
  int _revision = 0;

  CloudFile? _at(List<String> path) =>
      files.where((f) => listEquals(f.path, path)).firstOrNull;

  bool _exists(List<String> path) => _at(path) != null;

  @override
  void close() {}

  @override
  Future<FolderListing> listFolder(
    Account account,
    List<String> path, {
    bool metadataOnly = false,
    bool optional = false,
  }) async => FolderListing(
    self: _at(path),
    children: metadataOnly
        ? const []
        : files
              .where(
                (f) =>
                    f.path.length == path.length + 1 &&
                    pathStartsWith(f.path, path),
              )
              .toList(),
    revision: 'r$_revision',
  );

  @override
  Future<Map<String, CloudFile>> resolveFileIds(
    Account account,
    List<String> ids,
  ) async => {
    for (final file in files)
      if (file.id != null && ids.contains(file.id)) file.id!: file,
  };

  @override
  Future<List<CloudAlbum>> albums(
    Account account, {
    bool shared = false,
  }) async => shared
      ? []
      : const [
          CloudAlbum(name: 'Best days', reference: ['demo-album'], count: 3),
        ];

  @override
  Future<List<CloudAlbumMember>> albumFiles(
    Account account,
    CloudAlbum album,
  ) async => [
    for (final file in files.where((f) => f.isMedia && f.favorite))
      CloudAlbumMember(
        reference: file.path,
        id: file.id,
        originalName: file.name,
        displayName: file.name,
        contentType: file.contentType,
        size: file.size,
        modified: file.modified,
        revision: file.etag,
        favorite: file.favorite,
      ),
  ];

  @override
  Future<List<List<String>>> incomingSharedFolders(Account account) async =>
      const [];

  @override
  Future<List<RecognizedPerson>?> people(
    Account account, {
    List<String> path = const [],
    bool optional = false,
  }) async => null;

  @override
  Future<TimelineResult?> timeline(Account account, TimelineQuery query) async {
    if (!query.paged) return null;
    final matching =
        files
            .where(
              (f) =>
                  f.isMedia &&
                  pathStartsWith(f.path, query.path) &&
                  (query.recursive || f.path.length == query.path.length + 1) &&
                  (!query.favorites || f.favorite),
            )
            .toList()
          ..sort((a, b) {
            final order = (b.modified ?? DateTime(1970)).compareTo(
              a.modified ?? DateTime(1970),
            );
            return order == 0 ? a.key.compareTo(b.key) : order;
          });
    final start = int.tryParse(query.cursor ?? '') ?? 0;
    final end = (start + query.limit).clamp(0, matching.length);
    return TimelineResult.page(
      matching.sublist(start, end),
      end < matching.length ? '$end' : null,
    );
  }

  @override
  Future<List<Uint8List?>> previews(
    Account account,
    List<CloudFile> files, {
    int size = 384,
  }) async => [for (final _ in files) _png];

  @override
  Future<void> move(
    Account account,
    CloudFile file,
    List<String> destination,
  ) => _place(file, destination, copy: false);

  @override
  Future<void> copy(
    Account account,
    CloudFile file,
    List<String> destination,
  ) => _place(file, destination, copy: true);

  Future<void> _place(
    CloudFile file,
    List<String> target, {
    required bool copy,
  }) async {
    if (_exists(target)) {
      throw const CloudException('An item with that name already exists.');
    }
    final moved = [
      for (final f in files.where((f) => pathStartsWith(f.path, file.path)))
        f.atPath([...target, ...f.path.skip(file.path.length)]),
    ];
    if (!copy) files.removeWhere((f) => pathStartsWith(f.path, file.path));
    files.addAll(moved);
    _revision++;
  }

  @override
  Future<void> delete(Account account, CloudFile file) async {
    _trash['${file.key}:${_trash.length}'] = [
      for (final f in files.where((f) => pathStartsWith(f.path, file.path))) f,
    ];
    files.removeWhere((f) => pathStartsWith(f.path, file.path));
    _revision++;
  }

  @override
  Future<List<TrashEntry>> trash(Account account) async => [
    for (final entry in _trash.entries)
      TrashEntry(
        key: entry.key,
        name: entry.value.first.name,
        originalPath: entry.value.first.path.join('/'),
        deleted: DateTime.now(),
      ),
  ];

  @override
  Future<void> restore(Account account, TrashEntry entry) async {
    final restored = _trash[entry.key]!;
    if (_exists(restored.first.path)) {
      throw const CloudException(
        'An item already exists at the original location.',
      );
    }
    files.addAll(restored);
    _trash.remove(entry.key);
    _revision++;
  }

  @override
  Future<void> createFolder(Account account, List<String> path) async {
    if (_exists(path)) {
      throw const CloudException('An item with that name already exists.');
    }
    files.add(CloudFile(path: path, name: path.last, isDirectory: true));
    _revision++;
  }

  @override
  Future<void> setFavorite(Account account, CloudFile file, bool value) async {
    for (var i = 0; i < files.length; i++) {
      if (files[i].key == file.key) files[i] = files[i].withFavorite(value);
    }
    _revision++;
  }

  @override
  Stream<Set<String>?> changes(Account account) => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

/// A connected controller on [library], browsing without a day index.
AppController sampleController([SampleLibrary? library]) =>
    AppController(store: MemoryStore(), client: library ?? SampleLibrary())
      ..account = account.withPhotoRoot(['Photos'])
      ..timelineIndexAvailable = false;

/// Opens the app on a [sampleController] and waits for the library to show.
Future<AppController> pumpSampleLibrary(
  WidgetTester tester, {
  AppController? controller,
}) async {
  final c = controller ?? sampleController();
  await tester.pumpWidget(NcloudApp(controller: c));
  await tester.pumpAndSettle();
  return c;
}
