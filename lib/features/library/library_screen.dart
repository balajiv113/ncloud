import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_controller.dart';
import 'domain/album_entries.dart';
import 'domain/change_monitor.dart';
import 'domain/library_view.dart';
import 'albums_home.dart';
import 'album_context.dart';
import 'asset_viewer.dart';
import '../../discovery_models.dart';
import '../settings/settings_screen.dart';
import 'file_actions.dart';
import 'library_app_bar.dart';
import 'navigation_dock.dart';
import 'selection_bar.dart';
import 'view_options_sheet.dart';
import 'trash_screen.dart';
import '../../shared/ui/folder_picker.dart';
import '../../models.dart';
import '../photos/photo_map_screen.dart';
import '../../core/ui/messages.dart';
import 'library_dialogs.dart';
import '../photos/timeline_scrubber.dart';
import 'drive_list.dart';
import '../photos/memory_strip.dart';
import '../photos/timeline_grid.dart';
import '../photos/timeline_sections.dart';

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const _destinationOrder = [0, 4, 1];
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final Map<int, double> _destinationOffsets = {};
  late final AnimationController _destinationAnimation;
  late final CurvedAnimation _destinationCurve;
  late int _lastTab;
  double _destinationDirection = 1;
  int _navigationRequest = 0;
  Offset? _navigationDragStart;
  Offset _navigationDrag = Offset.zero;
  final Map<String, CloudFile> _selected = {};
  final Map<int, Offset> _pointers = {};
  final _tracker = TimelineTracker();
  final Set<int> _wantedDays = {};
  bool _requestScheduled = false;
  MediaFilter _filter = MediaFilter.all;
  LibrarySort _sort = LibrarySort.newest;
  List<String>? _subfolder;
  int _density = 3;
  int _pinchBase = 3;
  double _pinchStart = 0;
  bool _searching = false;
  bool _showPeople = false;
  bool _albumsExpanded = false;
  Object? _visibleKey;
  List<CloudFile> _visibleFiles = [];
  int _prefetchBudget = 2;
  String _query = '';
  AppController get c => widget.controller;
  bool get _album => c.tab == 4;
  bool get _drive => c.tab == 1;
  bool get _albumHome =>
      _album &&
      !c.smartAlbumOpen &&
      c.directory.isEmpty &&
      c.activeCloudAlbum == null &&
      c.activePerson == null &&
      c.activeMapBounds == null;
  bool get _collection => const [2, 5, 6].contains(c.tab);
  bool get _selecting => _selected.isNotEmpty;
  bool get _atNavigationRoot =>
      c.tab == 0 ||
      (_albumHome && !_albumsExpanded) ||
      (_drive && c.directory.isEmpty);
  bool get _canSwipeDestinations =>
      _atNavigationRoot &&
      !_selecting &&
      !_searching &&
      !c.busy &&
      !c.loading &&
      (ModalRoute.of(context)?.isCurrent ?? true);
  double get _span => _pointers.length == 2
      ? (_pointers.values.first - _pointers.values.last).distance
      : 0;

  ChangeMonitor? _changes;
  Account? _monitorAccount;
  AppController? _monitorController;
  bool? _monitorDemo;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _lastTab = c.tab;
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
  void didUpdateWidget(covariant LibraryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    _transitionTo(c.tab);
    _updateChangeMonitor(deferStart: true);
  }

  void _updateChangeMonitor({bool deferStart = false}) {
    if (identical(_monitorController, c) &&
        identical(_monitorAccount, c.account) &&
        _monitorDemo == c.demo) {
      return;
    }
    _changes?.dispose();
    _monitorController = c;
    _monitorAccount = c.account;
    _monitorDemo = c.demo;
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

  void _transitionTo(int tab) {
    if (tab == _lastTab) return;
    int index(int value) =>
        _destinationOrder.indexOf(const [2, 5, 6].contains(value) ? 4 : value);
    _destinationDirection = index(tab) >= index(_lastTab) ? 1 : -1;
    _lastTab = tab;
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
    final next = _destinationOrder.indexOf(c.tab) + (forward ? 1 : -1);
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
    if (!_foreground || _selecting) return false;
    final changed = await c.checkForChanges(changedFileIds: ids, force: pushed);
    if (!mounted) return changed;
    if (changed &&
        c.tab == 0 &&
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
        _selecting ||
        _query.isNotEmpty ||
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
    _selected.clear();
    _query = '';
    _searching = false;
    if (!keepAlbumSection) {
      _showPeople = false;
      _albumsExpanded = false;
    }
    _prefetchBudget = 2;
    _filter = MediaFilter.all;
    _subfolder = null;
    _wantedDays.clear();
    _tracker.clear();
  }

  Future<void> _navigate(int tab) async {
    _activity();
    final previous = c.tab;
    if (previous != tab && _atNavigationRoot && _scroll.hasClients) {
      _destinationOffsets[previous] = _scroll.offset;
    }
    final request = ++_navigationRequest;
    _resetView();
    _transitionTo(tab);
    await c.selectTab(tab);
    if (!mounted || previous == tab) return;
    final offset = _destinationOffsets[tab];
    if (offset == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          request != _navigationRequest ||
          c.tab != tab ||
          !_atNavigationRoot ||
          !_scroll.hasClients) {
        return;
      }
      _scroll.jumpTo(offset.clamp(0, _scroll.position.maxScrollExtent));
    });
  }

  void _back() {
    if (_selecting) {
      setState(() => _selected.clear());
    } else if (_albumHome && _albumsExpanded) {
      _resetView();
    } else if ((_album && !_albumHome) || c.tab == 5) {
      _resetView(keepAlbumSection: true);
      c.selectTab(4);
    } else if (_collection) {
      _navigate(4);
    } else {
      _resetView();
      c.goTo(c.directory.sublist(0, c.directory.length - 1));
    }
  }

  List<CloudFile> get _visible {
    final key = (
      c.items,
      _query,
      _subfolder,
      _filter,
      _sort,
      _drive,
      _collection,
    );
    if (key == _visibleKey) return _visibleFiles;
    _visibleKey = key;
    final files = filterAndSortFiles(
      c.items,
      query: _query,
      subfolder: _subfolder,
      filter: _filter,
      sort: _sort,
      drive: _drive,
      collection: _collection,
    );
    return _visibleFiles = files;
  }

  void _toggle(CloudFile file) {
    if (file.readOnly) return;
    HapticFeedback.selectionClick();
    setState(() {
      if (_selected.containsKey(file.key)) {
        _selected.remove(file.key);
      } else {
        _selected[file.key] = file;
      }
    });
  }

  void _open(CloudFile file, List<CloudFile> visible) {
    if (_selecting) {
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
    if (value == _density) return;
    final anchor = _scroll.hasClients
        ? _tracker.anchorAt(_scroll.offset)
        : null;
    setState(() => _density = value);
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
        (_albumHome && _albumsExpanded) ||
        (!_albumHome && (_album || _collection));
    final title =
        (c.activeMapBounds == null ? null : 'Photos in this area') ??
        c.activePerson?.label ??
        c.activeCloudAlbum?.name ??
        (_collection
            ? switch (c.tab) {
                2 => 'Favorites',
                5 => c.directory.last,
                _ => 'Offline',
              }
            : _album
            ? (_albumHome
                  ? (_albumsExpanded
                        ? (_showPeople ? 'People' : 'Albums')
                        : 'Albums')
                  : c.directory.lastOrNull ?? 'Photos')
            : _drive
            ? (c.directory.lastOrNull ?? 'Drive')
            : 'Timeline');
    return PopScope(
      canPop: !_selecting && !detail && c.directory.isEmpty && !c.busy,
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
                          _selected.clear();
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
                            _pinchBase = _density;
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
                              : _density;
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
                                title: _selecting
                                    ? '${_selected.length} selected'
                                    : c.directory.isNotEmpty ||
                                          c.activeCloudAlbum != null ||
                                          c.activePerson != null ||
                                          c.activeMapBounds != null ||
                                          (_albumHome && _albumsExpanded)
                                    ? title
                                    : 'ncloud',
                                showBack:
                                    _selecting ||
                                    detail ||
                                    c.directory.isNotEmpty,
                                selecting: _selecting,
                                busy: c.busy,
                                searching: _searching,
                                searchController: _search,
                                demo: c.demo,
                                initial: c.demo
                                    ? 'N'
                                    : (c
                                                  .account
                                                  ?.displayName
                                                  .characters
                                                  .firstOrNull ??
                                              'N')
                                          .toUpperCase(),
                                showSettings: !detail,
                                onBack: _back,
                                onQueryChanged: (value) =>
                                    setState(() => _query = value),
                                onToggleSearch: () => setState(() {
                                  _searching = !_searching;
                                  if (!_searching) {
                                    _query = '';
                                    _search.clear();
                                  }
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
                                          (!_indexedLayout &&
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
                              if (_drive && c.directory.isNotEmpty)
                                SliverToBoxAdapter(child: _breadcrumbs()),
                              if ((_album || c.tab == 5) &&
                                  !_albumHome &&
                                  c.activeCloudAlbum == null &&
                                  c.activePerson == null &&
                                  c.activeMapBounds == null)
                                SliverToBoxAdapter(
                                  child: AlbumContext(
                                    itemCount: c.items
                                        .where((f) => f.isMedia)
                                        .length,
                                    includesSubfolders:
                                        c.albumIncludesSubfolders,
                                    subfolders: subfolderPaths(
                                      c.items,
                                      c.directory,
                                    ),
                                    selected: _subfolder,
                                    canManageFolder: c.directory.isNotEmpty,
                                    onSelect: (path) =>
                                        setState(() => _subfolder = path),
                                    onOpenInDrive: () {
                                      setState(_reset);
                                      c.openFolder(c.currentFolder);
                                    },
                                    onFolderActions: () => fileActions(
                                      context,
                                      c,
                                      c.currentFolder,
                                    ),
                                  ),
                                ),
                              if (c.loading &&
                                  c.items.isEmpty &&
                                  !_indexedLayout &&
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
                                  query: _query,
                                  sort: _sort,
                                  expanded: _albumsExpanded,
                                  showPeople: _showPeople,
                                  actions: _albumActions,
                                )
                              else ...[
                                if (c.tab == 0 &&
                                    !_selecting &&
                                    _query.isEmpty &&
                                    _filter == MediaFilter.all)
                                  if (memoryGroups(files) case final groups
                                      when groups.isNotEmpty)
                                    SliverToBoxAdapter(
                                      child: MemoryStrip(
                                        groups: groups,
                                        controller: c,
                                        onOpen: _open,
                                      ),
                                    ),
                                if (_drive)
                                  _driveList(files)
                                else ...[
                                  ..._timelineSlivers(files),
                                  if (_collection &&
                                      files.any((f) => !f.isMedia))
                                    _driveList(
                                      files.where((f) => !f.isMedia).toList(),
                                    ),
                                ],
                                if (files.isEmpty && !_indexedLayout)
                                  SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: _empty(),
                                  ),
                              ],
                              if (c.loadingMore && !_indexedLayout)
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
                      Positioned(
                        right: 0,
                        top: 64,
                        bottom: 112,
                        width: 240,
                        child: TimelineScrubber(
                          controller: _scroll,
                          labelAt: (offset) => _tracker.labelAt(
                            offset,
                            MaterialLocalizations.of(context).formatMonthYear,
                          ),
                          markers: _tracker.yearMarkers,
                        ),
                      ),
                    if (c.tab == 0 && c.timelineChanged && !_selecting)
                      Positioned(
                        top: MediaQuery.paddingOf(context).top + 72,
                        left: 0,
                        right: 0,
                        child: Center(
                          child: FilledButton.icon(
                            onPressed: _showChanges,
                            style: FilledButton.styleFrom(
                              shape: const StadiumBorder(),
                              elevation: 4,
                            ),
                            icon: const Icon(Icons.arrow_upward, size: 18),
                            label: Text(switch (c.newPhotos) {
                              0 => 'Timeline updated',
                              1 => '1 new photo',
                              final n => '$n new photos',
                            }),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        floatingActionButton: _drive && !_selecting
            ? FloatingActionButton(
                tooltip: 'Add files',
                onPressed: c.busy ? null : _add,
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: _selecting
            ? SelectionBar(
                busy: c.busy,
                onAction: _bulk,
                onDone: () => setState(() => _selected.clear()),
              )
            : NavigationDock(
                active: _drive
                    ? 1
                    : _album || _collection
                    ? 4
                    : 0,
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

  Widget _breadcrumbs() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        TextButton(
          onPressed: () {
            setState(_reset);
            c.goTo([]);
          },
          child: const Text('All files'),
        ),
        for (var index = 0; index < c.directory.length; index++) ...[
          const Icon(Icons.chevron_right, size: 14),
          TextButton(
            onPressed: () {
              final path = c.directory.take(index + 1).toList();
              setState(_reset);
              c.goTo(path);
            },
            child: Text(c.directory[index]),
          ),
        ],
      ],
    ),
  );

  void _openCollection(int tab) {
    if (tab == 3) {
      Navigator.push(
        context,
        MaterialPageRoute<void>(builder: (_) => TrashScreen(controller: c)),
      );
    } else {
      _navigate(tab);
    }
  }

  void _openPerson(RecognizedPerson person) {
    _resetView(keepAlbumSection: true);
    c.openPerson(person);
  }

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
    openCollection: _openCollection,
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
      _albumsExpanded = true;
      _showPeople = people;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  /// Whether the full day index can lay out the whole timeline up
  /// front, so scrolling and scrubbing never wait at the end of a page.
  bool get _indexedLayout =>
      c.indexedDays.isNotEmpty &&
      _filter == MediaFilter.all &&
      _query.isEmpty &&
      _sort == LibrarySort.newest &&
      _subfolder == null;

  List<Widget> _timelineSlivers(List<CloudFile> files) {
    final media = files.where((f) => f.isMedia).toList();
    if (media.isEmpty && !_indexedLayout) {
      _tracker.clear();
      return const [];
    }
    final localizations = MaterialLocalizations.of(context);
    return [
      TimelineSlivers(
        controller: c,
        sections: buildTimelineSections(
          media: media,
          indexedDays: _indexedLayout ? c.indexedDays : null,
          dayLoaded: c.dayLoaded,
          dayNeedsRefresh: c.dayNeedsRefresh,
          labelFor: (date) => timelineLabel(
            date,
            byMonth: _density >= 5,
            formatMonth: localizations.formatMonthYear,
            formatDate: localizations.formatMediumDate,
          ),
        ),
        media: media,
        density: _density,
        tracker: _tracker,
        selected: _selected.keys.toSet(),
        selecting: _selecting,
        onOpen: _open,
        onToggle: _toggle,
        onToggleSection: _toggleSection,
        wantDays: _wantDays,
      ),
    ];
  }

  /// Selects every selectable file of a section, or clears them when all are
  /// already selected.
  void _toggleSection(List<CloudFile> files, bool all) => setState(() {
    for (final file in files.where((f) => !f.readOnly)) {
      if (all) {
        _selected.remove(file.key);
      } else {
        _selected[file.key] = file;
      }
    }
  });

  Widget _driveList(List<CloudFile> files) => DriveList(
    files: files,
    controller: c,
    selected: _selected.keys.toSet(),
    selecting: _selecting,
    onOpen: _open,
    onToggle: _toggle,
  );

  Widget _empty() => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            c.error == null ? Icons.photo_library_outlined : Icons.cloud_off,
            size: 44,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            c.error != null
                ? 'Connection interrupted'
                : c.hasMore
                ? 'Keep scrolling'
                : 'Nothing here yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 10),
          Text(
            c.error != null
                ? 'Your loaded items are kept. Pull to refresh and retry.'
                : c.hasMore
                ? 'More dates are available. Scroll to continue browsing.'
                : c.tab == 6
                ? 'Save originals from a file menu or video player to access them offline.'
                : c.tab == 5
                ? 'Photos you share from your cloud will appear here.'
                : c.activePerson != null
                ? 'This group has no photos here. Refresh People to check for changes.'
                : c.activeMapBounds != null
                ? 'No photos with saved coordinates in this area. Try a wider map view.'
                : _query.isNotEmpty || _filter != MediaFilter.all
                ? 'Try another search or view option.'
                : 'Add files in Drive to start your collection.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Future<void> _viewOptions() => showViewOptions(
    context,
    options: (filter: _filter, sort: _sort, density: _density),
    onChanged: (options) {
      setState(() {
        _filter = options.filter;
        _sort = options.sort;
      });
      _changeDensity(options.density);
    },
    drive: _drive,
    albumHome: _albumHome,
    showPeople: _showPeople,
    captureDates: c.timelineIndexAvailable == true,
    photoRoot: c.photoRoot,
    onChooseSource: _chooseSource,
  );

  Future<void> _bulk(String operation) async {
    final files = _selected.values
        .where(
          (f) => !_selected.values.any(
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
    if (mounted) setState(() => _selected.clear());
  }

  Future<void> _add() async {
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.upload_file_outlined),
              title: const Text('Upload files'),
              subtitle: Text('Destination: /${c.directory.join('/')}'),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: const Text('New folder'),
              onTap: () => Navigator.pop(context, 'folder'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    if (action == 'folder') {
      final name = await showDialog<String>(
        context: context,
        builder: (_) => const NameDialog(title: 'New folder'),
      );
      if (name != null) await c.createFolder(name);
      return;
    }
    if (c.demo) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Connect your cloud to upload your files.'),
        ),
      );
      return;
    }
    try {
      final account = c.account;
      final destination = [...c.directory];
      final picked = await FilePicker.platform.pickFiles(allowMultiple: true);
      if (picked == null) return;
      for (final file in picked.files) {
        if (c.account != account || !listEquals(c.directory, destination)) {
          throw const FormatException(
            'Destination changed. Select your files again.',
          );
        }
        await c.upload(file.name, file.xFile.openRead(), file.size);
        if (c.error != null) break;
      }
    } catch (e) {
      if (mounted) showError(context, e);
    }
  }
}
