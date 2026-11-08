import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/library/domain/library_view.dart';
import 'package:ncloud/models.dart';

CloudFile file(
  String name, {
  bool directory = false,
  String type = 'image/jpeg',
  int size = 1,
  DateTime? modified,
  bool favorite = false,
  List<String> parent = const ['Photos'],
}) => CloudFile(
  path: [...parent, name],
  name: name,
  isDirectory: directory,
  contentType: directory ? '' : type,
  size: size,
  modified: modified,
  favorite: favorite,
);

List<String> names(List<CloudFile> files) => [for (final f in files) f.name];

List<CloudFile> view(
  List<CloudFile> files, {
  String query = '',
  List<String>? subfolder,
  MediaFilter filter = MediaFilter.all,
  LibrarySort sort = LibrarySort.newest,
  bool drive = false,
  bool collection = false,
}) => filterAndSortFiles(
  files,
  query: query,
  subfolder: subfolder,
  filter: filter,
  sort: sort,
  drive: drive,
  collection: collection,
);

void main() {
  final day = DateTime(2024, 5, 1);
  final files = [
    file('b.jpg', modified: day, size: 5),
    file(
      'a.mp4',
      type: 'video/mp4',
      modified: day.add(const Duration(days: 2)),
    ),
    file('c.jpg', modified: day.add(const Duration(days: 1)), favorite: true),
    file('notes.txt', type: 'text/plain'),
    file('Trips', directory: true),
  ];

  test('Timeline views keep only media, newest first', () {
    expect(names(view(files)), ['a.mp4', 'c.jpg', 'b.jpg']);
    expect(names(view(files, sort: LibrarySort.oldest)), [
      'b.jpg',
      'c.jpg',
      'a.mp4',
    ]);
  });

  test('Drive keeps folders first and every file type', () {
    expect(names(view(files, drive: true, sort: LibrarySort.name)), [
      'Trips',
      'a.mp4',
      'b.jpg',
      'c.jpg',
      'notes.txt',
    ]);
  });

  test('collections also show non-media files', () {
    expect(names(view(files, collection: true)), contains('notes.txt'));
    expect(names(view(files)), isNot(contains('notes.txt')));
  });

  test('media filters and search combine', () {
    expect(names(view(files, filter: MediaFilter.videos)), ['a.mp4']);
    expect(names(view(files, filter: MediaFilter.photos)), ['c.jpg', 'b.jpg']);
    expect(names(view(files, filter: MediaFilter.favorites)), ['c.jpg']);
    expect(names(view(files, query: 'B.JP')), ['b.jpg']);
    expect(view(files, query: 'zzz'), isEmpty);
  });

  test('size sorts largest first and ties fall back to the key', () {
    expect(names(view(files, sort: LibrarySort.size)).first, 'b.jpg');
    final twins = [file('y.jpg'), file('x.jpg')];
    expect(names(view(twins)), ['x.jpg', 'y.jpg']);
  });

  test('a sub-folder limits the view to its files', () {
    final nested = [
      file('in.jpg', parent: ['Photos', 'Trip']),
      file('out.jpg'),
    ];
    expect(names(view(nested, subfolder: ['Photos', 'Trip'])), ['in.jpg']);
  });

  test('sub-folder chips list each child that holds media, once', () {
    final items = [
      file('a.jpg', parent: ['Photos', 'Trip', 'Day1']),
      file('b.jpg', parent: ['Photos', 'Trip', 'Day1']),
      file('c.jpg', parent: ['Photos', 'Trip', 'Day2']),
      file('d.jpg', parent: ['Photos', 'Trip']),
      file('notes.txt', type: 'text/plain', parent: ['Photos', 'Trip', 'Docs']),
    ];
    expect(subfolderPaths(items, ['Photos', 'Trip']), [
      ['Photos', 'Trip', 'Day1'],
      ['Photos', 'Trip', 'Day2'],
    ]);
    expect(subfolderPaths(items, ['Photos', 'Trip', 'Day1']), isEmpty);
  });
}
