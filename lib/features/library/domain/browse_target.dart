import '../../../discovery_models.dart';
import '../../../models.dart';

/// The top-level places the library switches between. Albums also hosts the
/// views opened from it; [sharedFolder] is an incoming shared folder opened
/// from the Albums list.
enum Destination { timeline, drive, favorites, albums, sharedFolder, offline }

/// What the library is showing: one value instead of a tab number plus the
/// folder, album, person and map area that go with it.
sealed class BrowseTarget {
  const BrowseTarget();

  Destination get destination;

  /// The folder shown, empty for views that are not folders.
  List<String> get path => const [];

  /// Stable text identifying this view, used to key its cached listing.
  String get cacheKey;

  /// This target at another folder. Only folder views move in place; any other
  /// target becomes a Drive folder.
  BrowseTarget inFolder(List<String> folder) => DriveTarget(folder);
}

final class TimelineTarget extends BrowseTarget {
  const TimelineTarget();

  @override
  Destination get destination => Destination.timeline;

  @override
  String get cacheKey => 'timeline';
}

final class FavoritesTarget extends BrowseTarget {
  const FavoritesTarget();

  @override
  Destination get destination => Destination.favorites;

  @override
  String get cacheKey => 'favorites';
}

final class OfflineTarget extends BrowseTarget {
  const OfflineTarget();

  @override
  Destination get destination => Destination.offline;

  @override
  String get cacheKey => 'offline';
}

/// The Albums overview.
final class AlbumHomeTarget extends BrowseTarget {
  const AlbumHomeTarget();

  @override
  Destination get destination => Destination.albums;

  @override
  String get cacheKey => 'albums';
}

final class DriveTarget extends BrowseTarget {
  DriveTarget(List<String> path) : path = List.unmodifiable(path);

  @override
  final List<String> path;

  @override
  Destination get destination => Destination.drive;

  @override
  String get cacheKey => 'drive:${path.join('/')}';

  @override
  BrowseTarget inFolder(List<String> folder) => DriveTarget(folder);
}

/// An album built from a folder of your files.
final class SmartAlbumTarget extends BrowseTarget {
  SmartAlbumTarget(List<String> path) : path = List.unmodifiable(path);

  @override
  final List<String> path;

  @override
  Destination get destination => Destination.albums;

  @override
  String get cacheKey => 'smart:${path.join('/')}';

  @override
  BrowseTarget inFolder(List<String> folder) => SmartAlbumTarget(folder);
}

/// A folder someone shared with this account.
final class SharedFolderTarget extends BrowseTarget {
  SharedFolderTarget(List<String> path) : path = List.unmodifiable(path);

  @override
  final List<String> path;

  @override
  Destination get destination => Destination.sharedFolder;

  @override
  String get cacheKey => 'shared:${path.join('/')}';

  @override
  BrowseTarget inFolder(List<String> folder) => SharedFolderTarget(folder);
}

/// An album stored on the server.
final class ServerAlbumTarget extends BrowseTarget {
  const ServerAlbumTarget(this.album);

  final CloudAlbum album;

  @override
  Destination get destination => Destination.albums;

  @override
  String get cacheKey => 'server:${album.reference.join('/')}';
}

/// Photos of one recognized person.
final class PersonTarget extends BrowseTarget {
  const PersonTarget(this.person);

  final RecognizedPerson person;

  @override
  Destination get destination => Destination.albums;

  @override
  String get cacheKey => 'person:${Uri.encodeComponent(person.id)}';
}

/// Photos taken inside a map area, which may be several rectangles when the
/// area crosses the antimeridian.
final class MapAreaTarget extends BrowseTarget {
  MapAreaTarget(List<PhotoMapBounds> bounds)
    : bounds = List.unmodifiable(bounds);

  final List<PhotoMapBounds> bounds;

  @override
  Destination get destination => Destination.albums;

  @override
  String get cacheKey => 'map:${bounds.map((b) => b.query).join(';')}';
}

/// The root target of each destination that has one.
BrowseTarget rootTarget(Destination destination) => switch (destination) {
  Destination.timeline => const TimelineTarget(),
  Destination.drive => DriveTarget(const []),
  Destination.favorites => const FavoritesTarget(),
  Destination.albums => const AlbumHomeTarget(),
  Destination.offline => const OfflineTarget(),
  Destination.sharedFolder => throw ArgumentError(
    'A shared folder needs a path; use SharedFolderTarget.',
  ),
};

extension DestinationSections on Destination {
  /// Opened from the Albums area, not from the bottom bar.
  bool get isCollection => switch (this) {
    Destination.favorites ||
    Destination.sharedFolder ||
    Destination.offline => true,
    _ => false,
  };

  /// The bottom-bar destination this one sits under.
  Destination get section => isCollection ? Destination.albums : this;
}
