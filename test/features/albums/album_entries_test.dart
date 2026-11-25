import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/model/backup_state.dart';
import 'package:ncloud/features/phone/phone_view.dart';
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
    CloudFile onPhone(String id, String album, DateTime when) => CloudFile(
      path: [CloudFile.phoneRoot, id],
      name: '$id.jpg',
      isDirectory: false,
      contentType: 'image/jpeg',
      modified: when,
      taken: when,
      captureDay: 1,
      onPhone: OnPhone(id, BackupState.waiting, album),
    );

    Map<String, PhoneView> phoneAlbums(Map<String, List<CloudFile>> byName) => {
      for (final e in byName.entries) e.key: PhoneView(e.value),
    };

    final camera = [
      onPhone('a', 'Camera', DateTime(2025, 3)),
      onPhone('b', 'Camera', DateTime(2025, 5)),
    ];
    final whatsapp = [onPhone('w', 'WhatsApp Images', DateTime(2025, 4))];

    List<AlbumEntry> withPhone(
      Map<String, List<CloudFile>> byName, {
      String query = '',
      LibrarySort sort = LibrarySort.name,
    }) => albumEntries(
      smart: smart,
      shared: shared,
      server: server,
      root: ['Photos'],
      query: query,
      sort: sort,
      phoneAlbums: phoneAlbums(byName),
    );

    test('mark the album the backup made from the same phone album', () {
      // "Beach" is one of the Smart albums above.
      final entries = withPhone({
        'Beach': [onPhone('a', 'Beach', DateTime(2025, 3))],
      });
      final beach = entries.singleWhere((e) => e.name == 'Beach');
      expect(beach.kind, AlbumKind.smart, reason: 'it is the same album');
      expect(beach.notBackedUp, 1);
      expect(beach.notBackedUpLabel, '1 not backed up');
      expect(entries.where((e) => e.kind == AlbumKind.phone), isEmpty);
      expect(
        entries
            .where((e) => e.name != 'Beach')
            .every((e) => e.notBackedUp == 0),
        isTrue,
      );
    });

    test('match the name whatever its case', () {
      final entries = withPhone({
        'beach': [onPhone('a', 'beach', DateTime(2025, 3))],
      });
      expect(entries.singleWhere((e) => e.name == 'Beach').notBackedUp, 1);
      expect(entries.where((e) => e.kind == AlbumKind.phone), isEmpty);
    });

    test('make an album of their own when the cloud has none', () {
      final entries = withPhone({'WhatsApp Images': whatsapp});
      final phone = entries.singleWhere((e) => e.kind == AlbumKind.phone);
      expect(phone.name, 'WhatsApp Images');
      expect(phone.count, '1 photo');
      expect(phone.notBackedUp, 1);
      expect(phone.kindLabel, 'Only on this phone');
      expect(phone.cover!.onPhone, isNotNull);
      expect(phone.key, 'phone|WhatsApp Images');
    });

    test('count the photos in an album that is only on the phone', () {
      final phone = withPhone({
        'Camera': camera,
      }).singleWhere((e) => e.kind == AlbumKind.phone);
      expect(phone.count, '2 photos');
      expect(phone.notBackedUpLabel, '2 not backed up');
      expect(phone.modified, DateTime(2025, 5));
    });

    test('leave the other albums unmarked, and add nothing without any', () {
      final plain = withPhone(const {});
      expect(
        plain.every((e) => e.notBackedUp == 0 && e.notBackedUpLabel == null),
        isTrue,
      );
      expect(names(plain), names(list(sort: LibrarySort.name)));
    });

    test('follow the search and the sort like any album', () {
      expect(
        withPhone({'WhatsApp Images': whatsapp}, query: 'whats').single.kind,
        AlbumKind.phone,
      );
      expect(withPhone({'WhatsApp Images': whatsapp}, query: 'zzz'), isEmpty);
      final sorted = withPhone({'Aaa Phone': whatsapp}, sort: LibrarySort.name);
      expect(sorted.first.name, 'Aaa');
    });
  });
}
