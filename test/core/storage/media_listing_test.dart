import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/core/storage/file_store.dart';
import 'package:ncloud/core/storage/media_listing.dart';
import 'package:ncloud/models.dart';

CloudFile photo(String name) => CloudFile(
  path: ['Photos', name],
  name: name,
  isDirectory: false,
  contentType: 'image/jpeg',
);

void main() {
  test('resolve gives the same list until the listing or store changes', () {
    final store = FileStore();
    final listing = MediaListing()
      ..add(store, [photo('a.jpg'), photo('b.jpg')]);
    final first = listing.resolve(store);
    expect(first.map((f) => f.name), ['a.jpg', 'b.jpg']);
    expect(identical(listing.resolve(store), first), isTrue);

    listing.add(store, [photo('c.jpg')]);
    final grown = listing.resolve(store);
    expect(grown, hasLength(3));
    expect(identical(grown, first), isFalse);

    store.putAll([photo('a.jpg').withFavorite(true)]);
    final patched = listing.resolve(store);
    expect(identical(patched, grown), isFalse);
    expect(patched.first.favorite, isTrue);
  });

  test('resolve reflects files removed from the store', () {
    final store = FileStore();
    final listing = MediaListing()
      ..add(store, [photo('a.jpg'), photo('b.jpg')]);
    expect(listing.resolve(store), hasLength(2));
    store.removeKeys([photo('a.jpg').key]);
    expect(listing.resolve(store).map((f) => f.name), ['b.jpg']);
  });

  test('merging a day replaces its photos and reports those that are gone', () {
    final store = FileStore();
    final day = DateTime.utc(2024, 5, 1);
    CloudFile onDay(String name) =>
        photo(name).withCaptureDate(day, null, day: 19844);
    final listing = MediaListing()
      ..days = const [TimelineDay(19844, 2)]
      ..add(store, [onDay('a.jpg'), onDay('b.jpg')])
      ..loaded.add(19844);
    final gone = listing.merge(
      store,
      FetchedPage([onDay('a.jpg')], days: const [19844]),
    );
    expect(gone, {onDay('b.jpg').key});
    expect(listing.resolve(store).map((f) => f.name), ['a.jpg']);
  });

  test(
    'applying a new index drops vanished days and returns those to reload',
    () {
      final store = FileStore();
      final listing = MediaListing()
        ..days = const [TimelineDay(3, 1), TimelineDay(2, 1), TimelineDay(1, 1)]
        ..loaded.addAll({3, 2, 1});
      final reload = listing.applyIndex(
        store,
        const [TimelineDay(3, 2), TimelineDay(1, 1)],
        {3, 2},
      );
      expect(reload, [3]);
      expect(listing.loaded, {3, 1});
      expect(listing.staleDays, {3});
      expect(listing.days!.map((d) => d.id), [3, 1]);
    },
  );
}
