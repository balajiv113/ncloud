import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/model/backup_state.dart';
import 'package:ncloud/features/albums/album_entries.dart';
import 'package:ncloud/app/shell/library_view.dart';
import 'package:ncloud/models.dart';

CloudFile cover(List<String> folder, DateTime modified) => CloudFile(
  path: [...folder, 'c.jpg'],
  name: 'c.jpg',
  isDirectory: false,
  contentType: 'image/jpeg',
  modified: modified,
);

SmartAlbum folder(List<String> path, DateTime modified) =>
    SmartAlbum(path: path, files: [cover(path, modified)]);

void main() {
  final smart = [
    folder(['Photos', 'Alps'], DateTime(2020)),
    folder(['Photos', 'Trips', 'Beach'], DateTime(2024)),
    folder(['Photos'], DateTime(2022)),
  ];
  final shared = [
    folder(['Shared', 'Cabin'], DateTime(2023)),
  ];
  const server = [
    CloudAlbum(name: 'Best days', reference: ['b'], count: 3, coverId: '9'),
    CloudAlbum(name: 'Aaa', reference: ['a'], count: 0),
  ];

  List<AlbumEntry> list({
    String query = '',
    LibrarySort sort = LibrarySort.size,
  }) => albumEntries(
    smart: smart,
    shared: shared,
    server: server,
    root: ['Photos'],
    query: query,
    sort: sort,
  );

  List<String> names(List<AlbumEntry> entries) => [
    for (final e in entries) e.name,
  ];

  test('all three sources form one list in discovery order', () {
    final entries = list();
    expect(names(entries), [
      'Alps',
      'Beach',
      'Photos at root',
      'Cabin',
      'Best days',
      'Aaa',
    ]);
    expect(
      [for (final e in entries) e.kind],
      [
        AlbumKind.smart,
        AlbumKind.smart,
        AlbumKind.smart,
        AlbumKind.shared,
        AlbumKind.server,
        AlbumKind.server,
      ],
    );
  });

  test('Smart albums show their parent folders and the source root name', () {
    final entries = list();
    expect(entries[0].subtitle, '');
    expect(entries[1].subtitle, 'Trips');
    expect(entries[2].name, 'Photos at root');
  });

  test('server albums carry their count and cover but no kind label', () {
    final best = list().firstWhere((e) => e.name == 'Best days');
    expect(best.count, '3 items');
    expect(best.cover?.id, '9');
    expect(best.kindLabel, isNull);
    expect(list().first.kindLabel, 'Smart album');
    expect(
      list().firstWhere((e) => e.kind == AlbumKind.shared).kindLabel,
      'Shared with you',
    );
  });

  test('names sort alphabetically across every source', () {
    expect(names(list(sort: LibrarySort.name)), [
      'Aaa',
      'Alps',
      'Beach',
      'Best days',
      'Cabin',
      'Photos at root',
    ]);
  });

  test('dates sort dated albums first and undated server albums last', () {
    expect(names(list(sort: LibrarySort.newest)), [
      'Beach',
      'Cabin',
      'Photos at root',
      'Alps',
      'Aaa',
      'Best days',
    ]);
    expect(names(list(sort: LibrarySort.oldest)), [
      'Alps',
      'Photos at root',
      'Cabin',
      'Beach',
      'Aaa',
      'Best days',
    ]);
  });

  test('search matches names, Smart album folders and every source', () {
    expect(names(list(query: 'trips')), ['Beach']);
    expect(names(list(query: 'ca')), ['Cabin']);
    expect(names(list(query: 'BEST')), ['Best days']);
    expect(list(query: 'zzz'), isEmpty);
  });

  test('keys are unique across sources with the same name', () {
    final twins = albumEntries(
      smart: [
        folder(['Photos', 'Trip'], DateTime(2020)),
      ],
      shared: [
        folder(['Shared', 'Trip'], DateTime(2020)),
      ],
      server: const [
        CloudAlbum(name: 'Trip', reference: ['t'], count: 1),
      ],
      root: ['Photos'],
      query: '',
      sort: LibrarySort.name,
    );
    expect({for (final e in twins) e.key}, hasLength(3));
  });

  group('photos only on the phone', () {
    final phonePhotos = [
      CloudFile(
        path: [CloudFile.phoneRoot, 'a'],
        name: 'a.jpg',
        isDirectory: false,
        contentType: 'image/jpeg',
        modified: DateTime(2025, 3),
        onPhone: const OnPhone('a', BackupState.leftOut),
      ),
      CloudFile(
        path: [CloudFile.phoneRoot, 'b'],
        name: 'b.jpg',
        isDirectory: false,
        contentType: 'image/jpeg',
        modified: DateTime(2025, 5),
        onPhone: const OnPhone('b', BackupState.waiting),
      ),
    ];

    List<AlbumEntry> withPhone({
      List<CloudFile>? notBackedUp,
      String query = '',
      LibrarySort sort = LibrarySort.name,
    }) => albumEntries(
      smart: smart,
      shared: shared,
      server: server,
      root: ['Photos'],
      query: query,
      sort: sort,
      notBackedUp: notBackedUp ?? phonePhotos,
    );

    test('make an album that comes first, whatever the sort', () {
      for (final sort in LibrarySort.values) {
        final first = withPhone(sort: sort).first;
        expect(first.kind, AlbumKind.phone);
        expect(first.name, 'Not backed up');
        expect(first.count, '2 photos');
        expect(first.kindLabel, 'Only on this phone');
        expect(first.cover!.onPhone, isNotNull);
        expect(first.modified, DateTime(2025, 5));
      }
    });

    test('are left out when there are none', () {
      expect(
        withPhone(notBackedUp: const []).any((e) => e.kind == AlbumKind.phone),
        isFalse,
      );
    });

    test('follow the search, and name one photo in the singular', () {
      expect(withPhone(query: 'zzz'), isEmpty);
      expect(withPhone(query: 'not back').single.kind, AlbumKind.phone);
      expect(
        withPhone(notBackedUp: [phonePhotos.first]).first.count,
        '1 photo',
      );
    });

    test('have a key of their own', () {
      expect(withPhone().first.key, 'phone|');
    });
  });
}
