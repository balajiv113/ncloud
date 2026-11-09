import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/app/browse_target.dart';
import 'package:ncloud/models.dart';

void main() {
  const person = RecognizedPerson(id: 'group:a/b', name: 'Ann', count: 3);
  const album = CloudAlbum(
    name: 'Trip',
    reference: ['albums', 'Trip'],
    count: 1,
  );
  final targets = <BrowseTarget>[
    const TimelineTarget(),
    DriveTarget(['Photos', 'Trip']),
    const FavoritesTarget(),
    const AlbumHomeTarget(),
    SmartAlbumTarget(['Photos', 'Trip']),
    SharedFolderTarget(['Shared', 'Trip']),
    const ServerAlbumTarget(album),
    const PersonTarget(person),
    MapAreaTarget([
      PhotoMapBounds(south: 1, north: 2, west: 3, east: 4),
      PhotoMapBounds(south: 1, north: 2, west: 5, east: 6),
    ]),
    const OfflineTarget(),
  ];

  test('every target has its own cache key', () {
    final keys = [for (final t in targets) t.cacheKey];
    expect(keys.toSet(), hasLength(keys.length));
  });

  test('keys do not mix folders of different views with the same path', () {
    expect(
      DriveTarget(['Photos']).cacheKey,
      isNot(SmartAlbumTarget(['Photos']).cacheKey),
    );
    expect(
      SmartAlbumTarget(['Photos']).cacheKey,
      isNot(SharedFolderTarget(['Photos']).cacheKey),
    );
  });

  test('destinations group the views opened from Albums', () {
    expect(
      [for (final t in targets) t.destination],
      [
        Destination.timeline,
        Destination.drive,
        Destination.favorites,
        Destination.albums,
        Destination.albums,
        Destination.sharedFolder,
        Destination.albums,
        Destination.albums,
        Destination.albums,
        Destination.offline,
      ],
    );
  });

  test('only folder views have a path', () {
    expect(DriveTarget(['a', 'b']).path, ['a', 'b']);
    expect(SmartAlbumTarget(['a']).path, ['a']);
    expect(SharedFolderTarget(['s']).path, ['s']);
    for (final target in [
      const TimelineTarget(),
      const AlbumHomeTarget(),
      const ServerAlbumTarget(album),
      const PersonTarget(person),
    ]) {
      expect(target.path, isEmpty);
    }
  });

  test('folder views move in place and others become Drive folders', () {
    expect(DriveTarget(['a']).inFolder(['b']), isA<DriveTarget>());
    expect(SmartAlbumTarget(['a']).inFolder(['b']), isA<SmartAlbumTarget>());
    expect(SharedFolderTarget(['a']).inFolder(['b']).path, ['b']);
    expect(const TimelineTarget().inFolder(['x']), isA<DriveTarget>());
  });

  test('paths cannot be changed after creation', () {
    final path = ['a'];
    final target = DriveTarget(path);
    path.add('b');
    expect(target.path, ['a']);
    expect(() => target.path.add('c'), throwsUnsupportedError);
  });

  test('root targets exist for every destination but shared folders', () {
    for (final destination in Destination.values) {
      if (destination == Destination.sharedFolder) {
        expect(() => rootTarget(destination), throwsArgumentError);
      } else {
        expect(rootTarget(destination).destination, destination);
      }
    }
  });
}
