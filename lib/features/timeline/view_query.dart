import 'package:flutter/foundation.dart';

import '../../app/browse_target.dart';
import '../../core/cloud/cloud_backend.dart';

/// What the server is asked for when a view is loaded: the view's target
/// together with the account settings that decide how it is fetched.
class ViewQuery {
  const ViewQuery(
    this.target, {
    required this.pathlessTimeline,
    required this.photoRoot,
  });

  final BrowseTarget target;

  /// Whether the server can resolve the main Timeline without folder paths.
  final bool pathlessTimeline;

  /// The folder the account keeps its photos in.
  final List<String> photoRoot;

  Destination get destination => target.destination;
  List<String> get path => target.path;

  /// The main Timeline, people and the map resolve paths on demand; albums
  /// need them for their sub-folder chips.
  bool get pathless =>
      (target.mapBounds != null ||
          target.person != null ||
          (pathlessTimeline && destination == Destination.timeline)) &&
      target.serverAlbum == null;

  /// Metadata-only batches are cheap, so a pathless view asks for many more
  /// photos per request than views that must look up paths.
  int get dayBatchLimit => pathless ? 1500 : 200;

  /// Whether media in sub-folders belongs to the view. Only a folder opened
  /// from the Albums list shows just its own photos.
  bool get recursive =>
      target.mapBounds != null ||
      target.person != null ||
      destination != Destination.albums ||
      !listEquals(path, photoRoot);

  /// The whole-library Timeline, whose days can be saved and reused.
  bool get isMainTimeline => target is TimelineTarget;

  TimelineQuery get index => TimelineQuery(
    path: path,
    favorites: destination == Destination.favorites,
    recursive: recursive,
    person: target.person,
    mapBounds: target.mapBounds,
  );

  TimelineQuery days(List<int> ids) => TimelineQuery(
    dayIds: ids,
    path: path,
    favorites: destination == Destination.favorites,
    recursive: recursive,
    resolvePaths: target.mapBounds == null && !pathless,
    person: target.person,
    mapBounds: target.mapBounds,
  );

  TimelineQuery page(String? cursor) => TimelineQuery.page(
    path: path,
    favorites: destination == Destination.favorites,
    cursor: cursor,
    recursive: recursive,
  );
}
