import '../../models.dart';
import '../app_controller.dart';
import '../browse_target.dart';
import 'library_view.dart';
import 'library_view_state.dart';

/// What a destination view gets from the shell: the state to read and the few
/// actions only the shell can perform, since it owns selection, scrolling and
/// navigation.
class LibraryScope {
  const LibraryScope({
    required this.controller,
    required this.view,
    required this.open,
    required this.toggle,
    required this.toggleSection,
    required this.wantDays,
    required this.reset,
    required this.selectSubfolder,
  });

  final AppController controller;
  final LibraryViewState view;

  /// Opens a file: its viewer, its folder, or its actions.
  final void Function(CloudFile file, List<CloudFile> visible) open;
  final void Function(CloudFile file) toggle;

  /// Selects, or when [all] are already selected clears, a group of files.
  final void Function(List<CloudFile> files, bool all) toggleSection;

  /// Asks for indexed days whose photos should load.
  final void Function(Iterable<int> days) wantDays;

  /// Leaves search, selection and filters behind and returns to the top.
  final void Function({bool keepAlbumSection}) reset;
  final void Function(List<String>? path) selectSubfolder;

  /// Whether the whole day index lays out the Timeline up front, so scrolling
  /// and scrubbing never wait at the end of a page.
  bool get indexedLayout =>
      controller.indexedDays.isNotEmpty && view.showsFullTimeline;

  /// What to tell the user when the view has nothing to show.
  String get emptyMessage {
    final c = controller;
    return c.error != null
        ? 'Your loaded items are kept. Pull to refresh and retry.'
        : c.hasMore
        ? 'More dates are available. Scroll to continue browsing.'
        : c.destination == Destination.offline
        ? 'Save originals from a file menu or video player to access them offline.'
        : c.destination == Destination.sharedFolder
        ? 'Photos you share from your cloud will appear here.'
        : c.activePerson != null
        ? 'This group has no photos here. Refresh People to check for changes.'
        : c.activeMapBounds != null
        ? 'No photos with saved coordinates in this area. Try a wider map view.'
        : view.query.isNotEmpty || view.filter != MediaFilter.all
        ? 'Try another search or view option.'
        : 'Add files in Drive to start your collection.';
  }
}
