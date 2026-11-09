import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/shell/library_view.dart';
import 'package:ncloud/app/shell/library_view_state.dart';
import 'package:ncloud/models.dart';

CloudFile file(String name, {List<String>? album, bool favorite = false}) =>
    CloudFile(
      path: ['Photos', name],
      name: name,
      isDirectory: false,
      contentType: 'image/jpeg',
      albumReference: album,
      favorite: favorite,
    );

void main() {
  test('selection toggles files and ignores read-only album members', () {
    final view = LibraryViewState();
    expect(view.selecting, isFalse);
    final a = file('a.jpg');
    view
      ..toggle(a)
      ..toggle(file('shared.jpg', album: ['x']));
    expect(view.selected.keys, [a.key]);
    expect(view.selecting, isTrue);
    view.toggle(a);
    expect(view.selecting, isFalse);
  });

  test('toggling a group selects it, then clears it once all are selected', () {
    final view = LibraryViewState();
    final files = [
      file('a.jpg'),
      file('b.jpg'),
      file('c.jpg', album: ['x']),
    ];
    view.toggleAll(files, false);
    expect(view.selected.keys, hasLength(2));
    view.toggleAll(files, true);
    expect(view.selecting, isFalse);
  });

  test(
    'reset clears narrowing but keeps sort, density and, on request, the section',
    () {
      final view = LibraryViewState()
        ..query = 'sun'
        ..searching = true
        ..filter = MediaFilter.videos
        ..sort = LibrarySort.name
        ..density = 5
        ..subfolder = ['Photos', 'Trip']
        ..albumsExpanded = true
        ..showPeople = true
        ..toggle(file('a.jpg'));
      view.reset(keepAlbumSection: true);
      expect(view.query, isEmpty);
      expect(view.searching, isFalse);
      expect(view.filter, MediaFilter.all);
      expect(view.subfolder, isNull);
      expect(view.selecting, isFalse);
      expect(view.sort, LibrarySort.name);
      expect(view.density, 5);
      expect(view.albumsExpanded, isTrue);
      expect(view.showPeople, isTrue);
      view.reset();
      expect(view.albumsExpanded, isFalse);
      expect(view.showPeople, isFalse);
    },
  );

  test('closing search clears its text but opening keeps it', () {
    final view = LibraryViewState()..toggleSearch();
    view.query = 'beach';
    expect(view.searching, isTrue);
    view.toggleSearch();
    expect(view.searching, isFalse);
    expect(view.query, isEmpty);
  });

  test('only the untouched newest-first view lays out the full index', () {
    final view = LibraryViewState();
    expect(view.showsFullTimeline, isTrue);
    for (final change in <void Function()>[
      () => view.query = 'a',
      () => view.filter = MediaFilter.photos,
      () => view.sort = LibrarySort.oldest,
      () => view.subfolder = ['Photos'],
    ]) {
      view.reset();
      view.sort = LibrarySort.newest;
      change();
      expect(view.showsFullTimeline, isFalse);
    }
  });

  test('visible files are reused until the items or a setting changes', () {
    final view = LibraryViewState();
    final items = [file('b.jpg'), file('a.jpg', favorite: true)];
    List<CloudFile> visible() =>
        view.visibleFiles(items, drive: false, collection: false);
    final first = visible();
    expect(identical(visible(), first), isTrue);
    view.filter = MediaFilter.favorites;
    final favorites = visible();
    expect(identical(favorites, first), isFalse);
    expect(favorites.map((f) => f.name), ['a.jpg']);
    expect(
      identical(
        view.visibleFiles([...items], drive: false, collection: false),
        favorites,
      ),
      isFalse,
    );
  });
}
