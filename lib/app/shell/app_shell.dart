import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_controller.dart';
import '../../features/albums/album_entries.dart';
import '../browse_target.dart';
import '../../features/timeline/change_monitor.dart';
import 'library_view_state.dart';
import '../../features/albums/albums_home.dart';
import '../../features/viewer/asset_viewer.dart';
import '../../discovery_models.dart';
import '../../features/settings/settings_screen.dart';
import '../../features/files/file_actions.dart';
import 'library_app_bar.dart';
import 'navigation_dock.dart';
import 'selection_bar.dart';
import 'view_options_sheet.dart';
import '../../features/files/trash_screen.dart';
import '../../shared/ui/folder_picker.dart';
import '../../models.dart';
import '../../features/map/photo_map_screen.dart';
import '../../core/ui/messages.dart';
import '../../features/albums/album_header.dart';
import '../../features/drive/add_files.dart';
import '../../features/drive/drive_view.dart';
import '../../features/timeline/timeline_overlays.dart';
import '../../features/timeline/timeline_view.dart';
import 'library_scope.dart';
import '../../features/timeline/timeline_sections.dart';

class AppShell extends StatefulWidget {
  const AppShell({super.key, required this.controller});
  final AppController controller;
  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _destinationOrder = [
    Destination.timeline,
    Destination.albums,
    Destination.drive,
  ];
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final Map<Destination, double> _destinationOffsets = {};
  late final AnimationController _destinationAnimation;
  late final CurvedAnimation _destinationCurve;
  late Destination _lastDestination;
  double _destinationDirection = 1;
  int _navigationRequest = 0;
  Offset? _navigationDragStart;
  Offset _navigationDrag = Offset.zero;
  final Map<int, Offset> _pointers = {};
  final _view = LibraryViewState();
  final _tracker = TimelineTracker();
  final Set<int> _wantedDays = {};
  bool _requestScheduled = false;
  int _pinchBase = 3;
  double _pinchStart = 0;
  int _prefetchBudget = 2;
  AppController get c => widget.controller;
  bool get _album => c.destination == Destination.albums;
  bool get _drive => c.destination == Destination.drive;
  bool get _albumHome =>
      _album &&
      !c.smartAlbumOpen &&
      c.directory.isEmpty &&
      c.activeCloudAlbum == null &&
      c.activePerson == null &&
      c.activeMapBounds == null;
  bool get _collection => c.destination.isCollection;
  bool get _atNavigationRoot =>
      c.destination == Destination.timeline ||
      (_albumHome && !_view.albumsExpanded) ||
      (_drive && c.directory.isEmpty);
  bool get _canSwipeDestinations =>
      _atNavigationRoot &&
      !_view.selecting &&
      !_view.searching &&
      !c.busy &&
      !c.loading &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  double get _span => _pointers.length == 2
      ? (_pointers.values.first - _pointers.values.last).distance
      : 0;

  ChangeMonitor? _changes;
  Account? _monitorAccount;
  AppController? _monitorController;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _lastDestination = c.destination;
    _destinationAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
      value: 1,
    );
    _destinationCurve = CurvedAnimation(
      parent: _destinationAnimation,
      curve: Curves.easeOutCubic,
    );
    _scroll.addListener(_prefetch);
    _scroll.addListener(_activity);
    WidgetsBinding.instance.addObserver(this);
    _updateChangeMonitor();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changes?.dispose();
    _search.dispose();
    _scroll.dispose();
    _destinationCurve.dispose();
    _destinationAnimation.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant AppShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _transitionTo(c.destination);
    _updateChangeMonitor(deferStart: true);
  }

  void _updateChangeMonitor({bool deferStart = false}) {
    if (identical(_monitorController, c) &&
        identical(_monitorAccount, c.account)) {
      return;
    }
    _changes?.dispose();
    _monitorController = c;
    _monitorAccount = c.account;
    final monitor = _changes = c.createChangeMonitor(_checkForChanges);
    void start() {
      if (mounted && _foreground && identical(_changes, monitor)) {
        monitor?.activity();
      }
    }

    if (deferStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) => start());
    } else {
      start();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _destinationAnimation.value = 1;
    }
  }

  void _transitionTo(Destination destination) {
    if (destination == _lastDestination) return;
    int index(Destination value) => _destinationOrder.indexOf(value.section);
    _destinationDirection = index(destination) >= index(_lastDestination)
        ? 1
        : -1;
    _lastDestination = destination;
    if (MediaQuery.disableAnimationsOf(context)) {
      _destinationAnimation.value = 1;
    } else {
      _destinationAnimation.forward(from: 0);
    }
  }

  void _startNavigationDrag(DragStartDetails details) {
    _navigationDrag = Offset.zero;
    _navigationDragStart = _canSwipeDestinations && _pointers.length == 1
        ? details.globalPosition
        : null;
  }

  void _updateNavigationDrag(DragUpdateDetails details) {
    if (_navigationDragStart case final start?) {
      _navigationDrag = details.globalPosition - start;
    }
  }

  void _endNavigationDrag(DragEndDetails details) {
    final delta = _navigationDrag;
    final allowed = _navigationDragStart != null && _canSwipeDestinations;
    _navigationDragStart = null;
    if (!allowed ||
        delta.dx.abs() < 72 ||
        delta.dx.abs() < delta.dy.abs() * 1.5) {
      return;
    }
    final forward = Directionality.of(context) == TextDirection.ltr
        ? delta.dx < 0
        : delta.dx > 0;
    final next = _destinationOrder.indexOf(c.destination) + (forward ? 1 : -1);
    if (next >= 0 && next < _destinationOrder.length) {
      _navigate(_destinationOrder[next]);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _changes?.setForeground(_foreground);
  }

  void _activity() => _changes?.activity();

  Future<bool> _checkForChanges(Set<String>? ids, bool pushed) async {
    if (!_foreground || _view.selecting) return false;
    final changed = await c.checkForChanges(changedFileIds: ids, force: pushed);
    if (!mounted) return changed;
    if (changed &&
        c.destination == Destination.timeline &&
        (!_scroll.hasClients || _scroll.offset < 120)) {
      c.applyChanges();
    }
    return changed;
  }

  void _showChanges() {
    c.applyChanges();
    if (_scroll.hasClients) {
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeOutCubic,
      );
    }
  }

  /// Queues indexed days whose placeholders became visible; the controller
  /// loads the most recently requested first.
  void _wantDays(Iterable<int> days) {
    _wantedDays.addAll(days);
    if (_requestScheduled) return;
    _requestScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _requestScheduled = false;
      if (!mounted || _wantedDays.isEmpty) return;
      final days = _wantedDays.toList();
      _wantedDays.clear();
      c.ensureDays(days);
    });
  }

  void _prefetch() {
    if (!_scroll.hasClients ||
        _albumHome ||
        _drive ||
        _view.selecting ||
        _view.query.isNotEmpty ||
        _prefetchBudget <= 0 ||
        c.loading ||
        c.loadingMore ||
        !c.hasMore ||
        c.error != null) {
      return;
    }
    if (_scroll.position.extentAfter < 600) {
      _prefetchBudget--;
      c.loadNextPage();
    }
  }

  /// Leaves search, selection and filters behind and returns to the top.
  void _resetView({bool keepAlbumSection = false}) {
    setState(() => _reset(keepAlbumSection: keepAlbumSection));
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _reset({bool keepAlbumSection = false}) {
    _search.clear();
    _view.reset(keepAlbumSection: keepAlbumSection);
    _prefetchBudget = 2;
    _wantedDays.clear();
    _tracker.clear();
  }

  Future<void> _navigate(Destination destination) async {
    _activity();
    final previous = c.destination;
    if (previous != destination && _atNavigationRoot && _scroll.hasClients) {
      _destinationOffsets[previous] = _scroll.offset;
    }
    final request = ++_navigationRequest;
    _resetView();
    _transitionTo(destination);
    await c.select(destination);
    if (!mounted || previous == destination) return;
    final offset = _destinationOffsets[destination];
    if (offset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _navigationRequest ||
          c.destination != destination ||
          !_atNavigationRoot ||
          !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  void _back() {
    if (_view.selecting) {
      setState(() => _view.selected.clear());
    } else if (_albumHome && _view.albumsExpanded) {
      _resetView();
    } else if ((_album && !_albumHome) ||
        c.destination == Destination.sharedFolder) {
      _resetView(keepAlbumSection: true);
      c.select(Destination.albums);
    } else if (_collection) {
      _navigate(Destination.albums);
    } else {
      _resetView();
      c.goTo(c.directory.sublist(0, c.directory.length - 1));
    }
  }

  List<CloudFile> get _visible =>
      _view.visibleFiles(c.items, drive: _drive, collection: _collection);

  void _toggle(CloudFile file) {
    if (file.readOnly) return;
    HapticFeedback.selectionClick();
    setState(() => _view.toggle(file));
  }

  void _open(CloudFile file, List<CloudFile> visible) {
    if (_view.selecting) {
      _toggle(file);
    } else if (file.isDirectory) {
      _resetView();
      c.openFolder(file);
    } else if (file.isMedia) {
      final media = visible.where((f) => f.isMedia).toList();
      Navigator.push(
        context,
        PageRouteBuilder<void>(
          transitionDuration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 180),
          reverseTransitionDuration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 150),
          pageBuilder: (_, _, _) => AssetViewer(
            files: media,
            initialIndex: media.indexWhere((f) => f.key == file.key),
            controller: c,
          ),
          transitionsBuilder: (_, animation, _, child) => FadeTransition(
            opacity: animation.drive(CurveTween(curve: Curves.easeOut)),
            child: child,
          ),
        ),
      );
    } else {
      fileActions(context, c, file);
    }
  }

  void _changeDensity(int value) {
    if (value == _view.density) return;
    final anchor = _scroll.hasClients
        ? _tracker.anchorAt(_scroll.offset)
        : null;
    setState(() => _view.density = value);
    if (anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        if (_tracker.offsetOf(anchor) case final offset?) {
          _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetch();
    });
    final files = _albumHome ? <CloudFile>[] : _visible;
    final theme = Theme.of(context);
    final detail =
        (_albumHome && _view.albumsExpanded) ||
        (!_albumHome && (_album || _collection));
    final title =
        (c.activeMapBounds == null ? null : 'Photos in this area') ??
        c.activePerson?.label ??
        c.activeCloudAlbum?.name ??
        (_collection
            ? switch (c.destination) {
                Destination.favorites => 'Favorites',
                Destination.sharedFolder => c.directory.last,
                _ => 'Offline',
              }
            : _album
            ? (_albumHome
                  ? (_view.albumsExpanded
                        ? (_view.showPeople ? 'People' : 'Albums')
                        : 'Albums')
                  : c.directory.lastOrNull ?? 'Photos')
            : _drive
            ? (c.directory.lastOrNull ?? 'Drive')
            : 'Timeline');
    return PopScope(
      canPop: !_view.selecting && !detail && c.directory.isEmpty && !c.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !c.busy) _back();
      },
      child: Scaffold(
        extendBody: true,
        body: SafeArea(
          bottom: false,
          child: GestureDetector(
            key: const ValueKey('destination-gestures'),
            behavior: HitTestBehavior.translucent,
            onHorizontalDragStart: _startNavigationDrag,
            onHorizontalDragUpdate: _updateNavigationDrag,
            onHorizontalDragEnd: _endNavigationDrag,
            onHorizontalDragCancel: () => _navigationDragStart = null,
            child: FadeTransition(
              key: const ValueKey('destination-fade'),
              opacity: Tween<double>(
                begin: .6,
                end: 1,
              ).animate(_destinationCurve),
              child: SlideTransition(
                key: const ValueKey('destination-slide'),
                textDirection: Directionality.of(context),
                position: Tween<Offset>(
                  begin: Offset(.045 * _destinationDirection, 0),
                  end: Offset.zero,
                ).animate(_destinationCurve),
                // Keep one live scroll tree: outgoing copies would share the
                // controller and continue requesting timeline pages.
                child: Stack(
                  children: [
                    RefreshIndicator(
                      onRefresh: () async {
                        setState(() {
                          _view.selected.clear();
                          _prefetchBudget = 2;
                        });
                        await c.load();
                      },
                      child: Listener(
                        onPointerDown: (event) {
                          _activity();
                          _pointers[event.pointer] = event.position;
                          if (_pointers.length == 2) {
                            _navigationDragStart = null;
                            _pinchBase = _view.density;
                            _pinchStart = _span;
                          }
                        },
                        onPointerMove: (event) {
                          if (!_pointers.containsKey(event.pointer)) return;
                          _pointers[event.pointer] = event.position;
                          if (_pointers.length != 2 ||
                              _drive ||
                              _albumHome ||
                              _pinchStart <= 0) {
                            return;
                          }
                          final scale = _span / _pinchStart;
                          final next = scale > 1.3
                              ? (_pinchBase - 1).clamp(2, 6)
                              : scale < .75
                              ? (_pinchBase + 1).clamp(2, 6)
                              : _view.density;
                          _changeDensity(next);
                        },
                        onPointerUp: (event) => _pointers.remove(event.pointer),
                        onPointerCancel: (event) =>
                            _pointers.remove(event.pointer),
                        child: NotificationListener<ScrollNotification>(
                          onNotification: (notification) {
                            if ((notification is ScrollUpdateNotification &&
                                    notification.dragDetails != null) ||
                                (notification is OverscrollNotification &&
                                    notification.dragDetails != null)) {
                              _prefetchBudget = 2;
                              _prefetch();
                            }
                            return false;
                          },
                          child: CustomScrollView(
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            // Builds and fetches roughly a screen ahead so tiles
                            // are painted before they scroll into view.
                            cacheExtent: 1200,
                            slivers: [
                              LibraryAppBar(
                                title: _view.selecting
                                    ? '${_view.selected.length} selected'
                                    : c.directory.isNotEmpty ||
                                          c.activeCloudAlbum != null ||
                                          c.activePerson != null ||
                                          c.activeMapBounds != null ||
                                          (_albumHome && _view.albumsExpanded)
                                    ? title
                                    : 'ncloud',
                                showBack:
                                    _view.selecting ||
                                    detail ||
                                    c.directory.isNotEmpty,
                                selecting: _view.selecting,
                                busy: c.busy,
                                searching: _view.searching,
                                searchController: _search,
                                initial:
                                    (c
                                                .account
                                                ?.displayName
                                                .characters
                                                .firstOrNull ??
                                            'N')
                                        .toUpperCase(),
                                showSettings: !detail,
                                onBack: _back,
                                onQueryChanged: (value) =>
                                    setState(() => _view.query = value),
                                onToggleSearch: () => setState(() {
                                  _view.toggleSearch();
                                  if (!_view.searching) _search.clear();
                                }),
                                onViewOptions: _viewOptions,
                                onSettings: () => Navigator.push(
                                  context,
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        SettingsScreen(controller: c),
                                  ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: SizedBox(
                                  height: 2,
                                  child:
                                      c.busy ||
                                          (!_scope.indexedLayout &&
                                              (c.refreshing || c.loadingMore))
                                      ? LinearProgressIndicator(
                                          minHeight: 2,
                                          value: c.busy && c.total > 0
                                              ? c.completed / c.total
                                              : null,
                                        )
                                      : null,
                                ),
                              ),
                              if ((c.error ??
                                      (_albumHome ? c.catalogueError : null))
                                  case final error?)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: MessageCard(
                                      message: error,
                                      isError: true,
                                      onRetry:
                                          c.loading || c.loadingMore || c.busy
                                          ? null
                                          : c.load,
                                    ),
                                  ),
                                ),
                              if (c.notice case final notice?)
                                SliverToBoxAdapter(
                                  child: Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                      16,
                                      8,
                                      16,
                                      4,
                                    ),
                                    child: Text(
                                      notice,
                                      style: TextStyle(
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                              if ((_album ||
                                      c.destination ==
                                          Destination.sharedFolder) &&
                                  !_albumHome &&
                                  c.activeCloudAlbum == null &&
                                  c.activePerson == null &&
                                  c.activeMapBounds == null)
                                SliverToBoxAdapter(
                                  child: AlbumHeader(scope: _scope),
                                ),
                              if (c.loading &&
                                  c.items.isEmpty &&
                                  !_scope.indexedLayout &&
                                  !_albumHome)
                                const SliverFillRemaining(
                                  hasScrollBody: false,
                                  child: Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                )
                              else if (_albumHome)
                                AlbumHomeSlivers(
                                  controller: c,
                                  query: _view.query,
                                  sort: _view.sort,
                                  expanded: _view.albumsExpanded,
                                  showPeople: _view.showPeople,
                                  actions: _albumActions,
                                )
                              else if (_drive)
                                DriveView(scope: _scope, files: files)
                              else
                                TimelineView(
                                  scope: _scope,
                                  files: files,
                                  tracker: _tracker,
                                ),
                              if (c.loadingMore && !_scope.indexedLayout)
                                const SliverToBoxAdapter(
                                  child: Padding(
                                    padding: EdgeInsets.all(16),
                                    child: Center(
                                      child: SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              const SliverToBoxAdapter(
                                child: SizedBox(height: 130),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (!_albumHome && !_drive)
                      ...timelineOverlays(
                        context,
                        controller: c,
                        scroll: _scroll,
                        tracker: _tracker,
                        selecting: _view.selecting,
                        showChanges: _showChanges,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        floatingActionButton: _drive && !_view.selecting
            ? FloatingActionButton(
                tooltip: 'Add files',
                onPressed: c.busy ? null : () => showAddFiles(context, c),
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: _view.selecting
            ? SelectionBar(
                busy: c.busy,
                onAction: _bulk,
                onDone: () => setState(() => _view.selected.clear()),
              )
            : NavigationDock(
                active: _drive
                    ? Destination.drive
                    : _album || _collection
                    ? Destination.albums
                    : Destination.timeline,
                busy: c.busy,
                onSelect: _navigate,
              ),
      ),
    );
  }

  Future<void> _chooseSource() async {
    final path = await chooseFolder(
      context,
      loadFolders: c.folderContents,
      sources: const [],
    );
    if (path != null && mounted) {
      setState(_reset);
      await c.setPhotoRoot(path);
    }
  }

  void _openTrash() => Navigator.push(
    context,
    MaterialPageRoute<void>(builder: (_) => TrashScreen(controller: c)),
  );

  void _openPerson(RecognizedPerson person) {
    _resetView(keepAlbumSection: true);
    c.openPerson(person);
  }

  late final _scope = LibraryScope(
    controller: c,
    view: _view,
    open: _open,
    toggle: _toggle,
    toggleSection: _toggleSection,
    wantDays: _wantDays,
    reset: _resetView,
    selectSubfolder: (path) => setState(() => _view.subfolder = path),
  );

  late final _albumActions = AlbumHomeActions(
    openAlbum: (album) {
      _resetView(keepAlbumSection: true);
      switch (album.kind) {
        case AlbumKind.smart:
          c.openSmartAlbum(album.path);
        case AlbumKind.shared:
          c.openSharedAlbum(album.path);
        case AlbumKind.server:
          c.openCloudAlbum(album.server!);
      }
    },
    openPerson: _openPerson,
    expandAlbums: () => _expandSection(),
    expandPeople: () => _expandSection(people: true),
    openMap: _openMap,
    openCollection: _navigate,
    openTrash: _openTrash,
  );

  void _openMap() {
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (mapContext) => PhotoMapScreen(
          controller: c,
          onOpenArea: (bounds) {
            Navigator.pop(mapContext);
            _resetView(keepAlbumSection: true);
            c.openMapArea(bounds);
          },
        ),
      ),
    );
  }

  void _expandSection({bool people = false}) {
    setState(() {
      _reset();
      _view.albumsExpanded = true;
      _view.showPeople = people;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Selects every selectable file of a section, or clears them when all are
  /// already selected.
  void _toggleSection(List<CloudFile> files, bool all) =>
      setState(() => _view.toggleAll(files, all));

  Future<void> _viewOptions() => showViewOptions(
    context,
    options: (filter: _view.filter, sort: _view.sort, density: _view.density),
    onChanged: (options) {
      setState(() {
        _view.filter = options.filter;
        _view.sort = options.sort;
      });
      _changeDensity(options.density);
    },
    drive: _drive,
    albumHome: _albumHome,
    showPeople: _view.showPeople,
    captureDates: c.timelineIndexAvailable == true,
    photoRoot: c.photoRoot,
    onChooseSource: _chooseSource,
  );

  Future<void> _bulk(String operation) async {
    final files = _view.selected.values
        .where(
          (f) => !_view.selected.values.any(
            (parent) =>
                parent.isDirectory &&
                parent.key != f.key &&
                pathStartsWith(f.path, parent.path),
          ),
        )
        .toList();
    List<String>? destination;
    if (operation == 'move' || operation == 'copy') {
      destination = await chooseFolder(
        context,
        loadFolders: c.folderContents,
        sources: files,
      );
      if (destination == null) return;
    }
    if (!mounted) return;
    if (operation == 'delete' && !await confirmDelete(context, files)) return;
    await c.organize(files, operation, destination: destination);
    if (mounted) setState(() => _view.selected.clear());
  }
}
