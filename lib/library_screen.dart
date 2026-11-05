import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'asset_viewer.dart';
import 'library_actions.dart';
import 'media_tile.dart';
import 'models.dart';
import 'screens.dart';
import 'timeline_layout.dart';

enum MediaFilter { all, photos, videos, favorites }

enum LibrarySort { newest, oldest, name, size }

typedef _AlbumCard = ({
  String name,
  String subtitle,
  String count,
  CloudFile? cover,
  VoidCallback open,
});

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen>
    with WidgetsBindingObserver {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, CloudFile> _selected = {};
  final Map<int, Offset> _pointers = {};
  final List<({double offset, String label, DateTime? date})> _dateStops = [];
  final Set<int> _wantedDays = {};
  bool _requestScheduled = false;
  final List<({double offset, List<CloudFile> files})> _rowPositions = [];
  MediaFilter _filter = MediaFilter.all;
  LibrarySort _sort = LibrarySort.newest;
  List<String>? _subfolder;
  int _density = 3;
  int _pinchBase = 3;
  double _pinchStart = 0;
  double _timelineStart = 0;
  bool _searching = false;
  bool _showNative = false;
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
      c.activeNativeAlbum == null;
  bool get _collection => const [2, 5, 6].contains(c.tab);
  bool get _sharedHome => c.sharedAlbumHome;
  bool get _selecting => _selected.isNotEmpty;
  double get _span => _pointers.length == 2
      ? (_pointers.values.first - _pointers.values.last).distance
      : 0;

  Timer? _changePoll;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_prefetch);
    WidgetsBinding.instance.addObserver(this);
    _changePoll = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _checkForChanges(),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _changePoll?.cancel();
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) _checkForChanges();
  }

  /// Picks up photos added or removed in Nextcloud while the Timeline is
  /// open: applied in place at the top, otherwise offered as a pill.
  Future<void> _checkForChanges() async {
    if (!_foreground || c.tab != 0 || _selecting) return;
    if (!await c.checkForChanges() || !mounted) return;
    if (!_scroll.hasClients || _scroll.offset < 120) c.applyChanges();
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

  /// Month shown in the scrubber bubble for a scroll offset.
  String? _labelAt(double offset) {
    DateTime? date;
    for (final stop in _dateStops) {
      if (stop.offset > offset - _timelineStart + 56) break;
      date = stop.date ?? date;
    }
    date ??= _dateStops.firstOrNull?.date;
    return date == null
        ? null
        : MaterialLocalizations.of(context).formatMonthYear(date);
  }

  /// Year markers shown beside the scrubber track while dragging.
  List<({double offset, String label})> _yearMarkers() {
    final markers = <({double offset, String label})>[];
    int? year;
    for (final stop in _dateStops) {
      final date = stop.date;
      if (date == null || date.year == year) continue;
      year = date.year;
      markers.add((offset: _timelineStart + stop.offset, label: '$year'));
    }
    return markers;
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
        _sharedHome ||
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

  void _reset({bool keepAlbumSection = false}) {
    _search.clear();
    _selected.clear();
    _query = '';
    _searching = false;
    if (!keepAlbumSection) {
      _showNative = false;
      _albumsExpanded = false;
    }
    _prefetchBudget = 2;
    _filter = MediaFilter.all;
    _subfolder = null;
    _wantedDays.clear();
    _dateStops.clear();
    _rowPositions.clear();
  }

  void _navigate(int tab) {
    setState(_reset);
    if (_scroll.hasClients) _scroll.jumpTo(0);
    c.selectTab(tab);
  }

  void _back() {
    if (_selecting) {
      setState(() => _selected.clear());
    } else if (_albumHome && _albumsExpanded) {
      setState(_reset);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (_album && !_albumHome) {
      setState(() => _reset(keepAlbumSection: true));
      if (_scroll.hasClients) _scroll.jumpTo(0);
      c.selectTab(4);
    } else if (c.tab == 5 && !_sharedHome) {
      setState(_reset);
      if (_scroll.hasClients) _scroll.jumpTo(0);
      c.selectTab(5);
    } else if (_collection) {
      _navigate(4);
    } else {
      setState(_reset);
      c.goTo(c.directory.sublist(0, c.directory.length - 1));
      if (_scroll.hasClients) _scroll.jumpTo(0);
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
    final files = c.items.where((f) {
      if (_query.isNotEmpty &&
          !f.name.toLowerCase().contains(_query.toLowerCase())) {
        return false;
      }
      if (_subfolder != null && !pathStartsWith(f.path, _subfolder!)) {
        return false;
      }
      if (f.isDirectory) return _drive;
      if (!_drive && !f.isMedia && !_collection) return false;
      return switch (_filter) {
        MediaFilter.all => true,
        MediaFilter.photos => f.isImage,
        MediaFilter.videos => f.isVideo,
        MediaFilter.favorites => f.favorite,
      };
    }).toList();
    files.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      var newest = (b.timelineDate ?? DateTime(1970)).compareTo(
        a.timelineDate ?? DateTime(1970),
      );
      if (newest == 0) {
        newest = (b.taken ?? DateTime(1970)).compareTo(
          a.taken ?? DateTime(1970),
        );
      }
      final order = switch (_sort) {
        LibrarySort.newest => newest,
        LibrarySort.oldest => -newest,
        LibrarySort.name => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ),
        LibrarySort.size => b.size.compareTo(a.size),
      };
      return order == 0 ? a.key.compareTo(b.key) : order;
    });
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
      setState(_reset);
      c.openFolder(file);
      if (_scroll.hasClients) _scroll.jumpTo(0);
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

  void _openSmart(List<String> path) {
    setState(() => _reset(keepAlbumSection: true));
    if (_scroll.hasClients) _scroll.jumpTo(0);
    c.openSmartAlbum(path);
  }

  void _changeDensity(int value) {
    if (value == _density) return;
    String? anchor;
    if (_scroll.hasClients && _scroll.offset > _timelineStart) {
      for (final row in _rowPositions) {
        if (row.offset > _scroll.offset - _timelineStart) break;
        anchor = row.files.first.key;
      }
    }
    setState(() => _density = value);
    if (anchor != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scroll.hasClients) return;
        final row = _rowPositions
            .where((r) => r.files.any((f) => f.key == anchor))
            .firstOrNull;
        if (row != null) {
          _scroll.jumpTo(
            (_timelineStart + row.offset).clamp(
              0,
              _scroll.position.maxScrollExtent,
            ),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _prefetch();
    });
    final files = _albumHome || _sharedHome ? <CloudFile>[] : _visible;
    final theme = Theme.of(context);
    final detail =
        (_albumHome && _albumsExpanded) ||
        (!_albumHome && (_album || _collection));
    final title =
        c.activeNativeAlbum?.name ??
        (_collection
            ? switch (c.tab) {
                2 => 'Favorites',
                5 => _sharedHome ? 'Shared with you' : c.directory.last,
                _ => 'Offline',
              }
            : _album
            ? (_albumHome
                  ? (_albumsExpanded
                        ? (_showNative ? 'Nextcloud albums' : 'Smart albums')
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
                    _pointers[event.pointer] = event.position;
                    if (_pointers.length == 2) {
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
                  onPointerCancel: (event) => _pointers.remove(event.pointer),
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
                        SliverAppBar(
                          floating: true,
                          snap: true,
                          automaticallyImplyLeading: false,
                          leading:
                              _selecting || detail || c.directory.isNotEmpty
                              ? IconButton(
                                  tooltip: _selecting
                                      ? 'Cancel selection'
                                      : 'Back',
                                  onPressed: c.busy ? null : _back,
                                  icon: Icon(
                                    _selecting ? Icons.close : Icons.arrow_back,
                                  ),
                                )
                              : null,
                          titleSpacing: 16,
                          title: _searching
                              ? TextField(
                                  controller: _search,
                                  autofocus: true,
                                  onChanged: (value) =>
                                      setState(() => _query = value),
                                  decoration: const InputDecoration(
                                    hintText: 'Search',
                                    isDense: true,
                                    contentPadding: EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 10,
                                    ),
                                  ),
                                )
                              : Text(
                                  _selecting
                                      ? '${_selected.length} selected'
                                      : detail
                                      ? title
                                      : _albumHome
                                      ? 'Albums'
                                      : 'ncloud',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: -.7,
                                  ),
                                ),
                          actions: [
                            if (c.demo && !_searching && !_selecting)
                              Center(
                                child: Text(
                                  'DEMO',
                                  style: TextStyle(
                                    fontSize: 9,
                                    letterSpacing: 1,
                                    color: theme.colorScheme.primary,
                                  ),
                                ),
                              ),
                            if (!_selecting) ...[
                              IconButton(
                                tooltip: 'Search loaded items',
                                icon: Icon(
                                  _searching ? Icons.close : Icons.search,
                                ),
                                onPressed: () => setState(() {
                                  _searching = !_searching;
                                  if (!_searching) {
                                    _query = '';
                                    _search.clear();
                                  }
                                }),
                              ),
                              IconButton(
                                tooltip: 'View options',
                                onPressed: _viewOptions,
                                icon: const Icon(Icons.tune_rounded),
                              ),
                              if (!detail)
                                IconButton(
                                  tooltip: 'Settings',
                                  onPressed: () => Navigator.push(
                                    context,
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          SettingsScreen(controller: c),
                                    ),
                                  ),
                                  icon: CircleAvatar(
                                    radius: 15,
                                    backgroundColor:
                                        theme.colorScheme.primaryContainer,
                                    child: Text(
                                      c.demo
                                          ? 'N'
                                          : (c
                                                        .account
                                                        ?.displayName
                                                        .characters
                                                        .firstOrNull ??
                                                    'N')
                                                .toUpperCase(),
                                      style: TextStyle(
                                        fontSize: 11,
                                        height: 1.4,
                                        fontWeight: FontWeight.w700,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                            const SizedBox(width: 4),
                          ],
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
                                (_albumHome
                                    ? c.catalogueError
                                    : _sharedHome
                                    ? c.sharedAlbumError
                                    : null))
                            case final error?)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: MessageCard(
                                message: error,
                                isError: true,
                                onRetry: c.loading || c.loadingMore || c.busy
                                    ? null
                                    : c.load,
                              ),
                            ),
                          ),
                        if (c.notice case final notice?)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                              child: Text(
                                notice,
                                style: TextStyle(
                                  color: theme.colorScheme.primary,
                                ),
                              ),
                            ),
                          ),
                        if (_drive)
                          SliverToBoxAdapter(
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 8, 12, 12),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.headlineMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w700,
                                            letterSpacing: -.8,
                                          ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        if (_drive && c.directory.isNotEmpty)
                          SliverToBoxAdapter(child: _breadcrumbs()),
                        if ((_album || (c.tab == 5 && !_sharedHome)) &&
                            !_albumHome &&
                            c.activeNativeAlbum == null)
                          SliverToBoxAdapter(child: _albumContext()),
                        if (c.loading &&
                            c.items.isEmpty &&
                            !_indexedLayout &&
                            !_albumHome &&
                            !_sharedHome)
                          const SliverFillRemaining(
                            hasScrollBody: false,
                            child: Center(child: CircularProgressIndicator()),
                          )
                        else if (_albumHome)
                          ..._albumHomeSlivers()
                        else if (_sharedHome)
                          ..._sharedAlbumSlivers()
                        else ...[
                          if (c.tab == 0 &&
                              !_selecting &&
                              _query.isEmpty &&
                              _filter == MediaFilter.all)
                            if (_memoryGroups(files).isNotEmpty)
                              SliverToBoxAdapter(child: _memoryStrip(files)),
                          if (_drive)
                            _driveSliver(files)
                          else ...[
                            ..._timelineSlivers(files),
                            if (_collection && files.any((f) => !f.isMedia))
                              _driveSliver(
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
                        const SliverToBoxAdapter(child: SizedBox(height: 130)),
                      ],
                    ),
                  ),
                ),
              ),
              if (!_albumHome && !_sharedHome && !_drive)
                Positioned(
                  right: 0,
                  top: 64,
                  bottom: 112,
                  width: 240,
                  child: _TimelineScrubber(
                    controller: _scroll,
                    labelAt: _labelAt,
                    markers: _yearMarkers,
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
        floatingActionButton: _drive && !_selecting
            ? FloatingActionButton(
                tooltip: 'Add files',
                onPressed: c.busy ? null : _add,
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: _selecting ? _selectionBar() : _navigation(),
      ),
    );
  }

  Widget _navigation() {
    final colors = Theme.of(context).colorScheme;
    final active = _drive
        ? 1
        : _album || _collection
        ? 4
        : 0;
    final destinations = [
      (0, 'Timeline', Icons.photo_library_outlined),
      (4, 'Albums', Icons.collections_bookmark_outlined),
      (1, 'Drive', Icons.folder_outlined),
    ];
    final activeIndex = destinations.indexWhere((d) => d.$1 == active);
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 240);
    final fullWidth = (MediaQuery.sizeOf(context).width - 40).clamp(0.0, 440.0);
    final width = fullWidth.clamp(0.0, 268.0);
    return SafeArea(
      top: false,
      child: SizedBox(
        height: 96,
        child: Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: AnimatedContainer(
              key: const ValueKey('navigation-dock'),
              duration: duration,
              curve: Curves.easeOutCubic,
              width: width,
              height: 60,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: colors.shadow.withValues(alpha: .12),
                    blurRadius: 24,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(30),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                  child: Material(
                    color: colors.surface.withValues(alpha: .94),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                      side: BorderSide(
                        color: colors.outlineVariant.withValues(alpha: .5),
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final selectedWidth = constraints.maxWidth * .46;
                          final otherWidth =
                              (constraints.maxWidth - selectedWidth) / 2;
                          return Stack(
                            children: [
                              AnimatedPositioned(
                                duration: duration,
                                curve: Curves.easeOutCubic,
                                left: activeIndex * otherWidth,
                                top: 0,
                                bottom: 0,
                                width: selectedWidth,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: colors.primaryContainer,
                                    borderRadius: BorderRadius.circular(24),
                                  ),
                                ),
                              ),
                              Row(
                                children: [
                                  for (final (tab, label, icon) in destinations)
                                    Expanded(
                                      flex: active == tab ? 46 : 27,
                                      child: Tooltip(
                                        message: label,
                                        child: Semantics(
                                          selected: tab == active,
                                          button: true,
                                          label: label,
                                          excludeSemantics: true,
                                          child: InkWell(
                                            key: ValueKey('navigate-$tab'),
                                            borderRadius: BorderRadius.circular(
                                              28,
                                            ),
                                            onTap: c.busy
                                                ? null
                                                : () => _navigate(tab),
                                            child: SizedBox.expand(
                                              child: Row(
                                                mainAxisAlignment:
                                                    MainAxisAlignment.center,
                                                children: [
                                                  Icon(
                                                    icon,
                                                    size: 21,
                                                    color: active == tab
                                                        ? colors
                                                              .onPrimaryContainer
                                                        : colors
                                                              .onSurfaceVariant,
                                                  ),
                                                  if (active == tab) ...[
                                                    const SizedBox(width: 6),
                                                    Flexible(
                                                      child: Text(
                                                        tab == 0
                                                            ? 'Photos'
                                                            : label,
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                        style: TextStyle(
                                                          fontSize: 12,
                                                          fontWeight:
                                                              FontWeight.w600,
                                                          color: active == tab
                                                              ? colors
                                                                    .onPrimaryContainer
                                                              : colors
                                                                    .onSurfaceVariant,
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ],
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _chooseSource() async {
    final path = await chooseFolder(context, c, []);
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

  void _expandAlbums(bool native) {
    setState(() {
      _reset();
      _albumsExpanded = true;
      _showNative = native;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _albumSectionHeading(String title, {VoidCallback? expand}) =>
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: InkWell(
                  onTap: expand,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              if (expand != null)
                TextButton(
                  key: ValueKey('View all $title'),
                  onPressed: expand,
                  child: const Text('View all'),
                ),
            ],
          ),
        ),
      );

  Widget _pinnedCollections() => SliverToBoxAdapter(
    child: SizedBox(
      height: 100 + MediaQuery.textScalerOf(context).scale(12) * 1.4,
      child: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        scrollDirection: Axis.horizontal,
        itemCount: 3,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final (label, icon, tab) = [
            ('Favorites', Icons.favorite_border, 2),
            ('Offline', Icons.offline_bolt_outlined, 6),
            ('Bin', Icons.restore_from_trash_outlined, 3),
          ][index];
          return SizedBox(
            width: 84,
            child: Tooltip(
              message: tab == 3 ? 'Recently deleted' : label,
              child: Material(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(20),
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => _openCollection(tab),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, size: 28),
                      const SizedBox(height: 16),
                      Text(label, style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  Widget _albumArtwork(_AlbumCard album) => album.cover == null
      ? ColoredBox(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: const Center(
            child: Icon(Icons.photo_album_outlined, size: 38),
          ),
        )
      : ExcludeSemantics(
          child: MediaTile(file: album.cover!, controller: c),
        );

  Widget _albumPreview(List<_AlbumCard> albums) => SliverToBoxAdapter(
    child: SizedBox(
      height: 180 + (MediaQuery.textScalerOf(context).scale(13) - 13) * 2.8,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: albums.length.clamp(0, 8),
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) {
          final album = albums[index];
          return SizedBox(
            width: 144,
            child: Semantics(
              button: true,
              label: album.name,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    _albumArtwork(album),
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.center,
                          end: Alignment.bottomCenter,
                          colors: [Colors.transparent, Color(0xD9000000)],
                        ),
                      ),
                    ),
                    Positioned(
                      left: 12,
                      right: 12,
                      bottom: 14,
                      child: ExcludeSemantics(
                        child: Text(
                          album.name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(onTap: album.open),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    ),
  );

  List<Widget> _albumHomeSlivers() {
    final root = c.photoRoot;
    final smartAlbums = c.smartAlbums;
    var albums = smartAlbums
        .where(
          (a) =>
              (_query.isEmpty ||
              '${a.name} ${a.path.join(' ')}'.toLowerCase().contains(
                _query.toLowerCase(),
              )),
        )
        .toList();
    if (_sort == LibrarySort.newest || _sort == LibrarySort.oldest) {
      DateTime date(SmartAlbum album) => album.files
          .map((f) => f.modified ?? DateTime(1970))
          .reduce((a, b) => a.isAfter(b) ? a : b);
      final dates = {for (final album in albums) album.key: date(album)};
      albums.sort(
        (a, b) => _sort == LibrarySort.newest
            ? dates[b.key]!.compareTo(dates[a.key]!)
            : dates[a.key]!.compareTo(dates[b.key]!),
      );
    } else if (_sort == LibrarySort.name) {
      albums.sort(
        (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
      );
    }
    final native = c.nativeAlbums
        .where(
          (a) =>
              _query.isEmpty ||
              a.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    final sharedCards = _sharedCards();
    final smartCards = albums
        .map(
          (a) => (
            name: listPathEquals(a.path, root) ? 'Photos at root' : a.name,
            subtitle: a.path.length <= root.length + 1
                ? ''
                : a.path
                      .skip(root.length)
                      .take(a.path.length - root.length - 1)
                      .join(' / '),
            count: '',
            cover: a.files.first,
            open: () => _openSmart(a.path),
          ),
        )
        .toList();
    final nativeCards = native
        .map(
          (a) => (
            name: a.name,
            subtitle: a.shared ? 'Shared album' : 'Nextcloud album',
            count: '${a.count} items',
            cover: a.coverId == null
                ? null
                : CloudFile(
                    path: ['album-cover', ...a.davPath],
                    name: a.name,
                    isDirectory: false,
                    id: a.coverId,
                    contentType: 'image/jpeg',
                  ),
            open: () {
              setState(() => _reset(keepAlbumSection: true));
              if (_scroll.hasClients) _scroll.jumpTo(0);
              c.openNativeAlbum(a);
            },
          ),
        )
        .toList();
    if (!_albumsExpanded) {
      return [
        _albumSectionHeading('Pinned'),
        _pinnedCollections(),
        _albumSectionHeading(
          'Smart albums',
          expand: () => _expandAlbums(false),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 8),
            child: SizedBox(
              height: 2,
              child: c.discoveringAlbums
                  ? const LinearProgressIndicator(minHeight: 2)
                  : null,
            ),
          ),
        ),
        if (smartCards.isNotEmpty)
          _albumPreview(smartCards)
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Text(
                _query.isNotEmpty
                    ? 'No matching Smart albums.'
                    : c.discoveringAlbums
                    ? 'Discovering your photo folders...'
                    : 'No photo albums yet. Choose a photo source in View options.',
              ),
            ),
          ),
        _albumSectionHeading(
          'Shared with you',
          expand: () => _openCollection(5),
        ),
        if (sharedCards.isNotEmpty)
          _albumPreview(sharedCards)
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Text(
                c.loadingSharedAlbums
                    ? 'Loading folders shared with you...'
                    : 'Incoming photo folders appear here.',
              ),
            ),
          ),
        if (c.sharedAlbumError case final error?)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MessageCard(
                message: error,
                isError: true,
                onRetry: c.load,
              ),
            ),
          ),
        _albumSectionHeading(
          'Nextcloud albums',
          expand: () => _expandAlbums(true),
        ),
        if (nativeCards.isNotEmpty)
          _albumPreview(nativeCards)
        else if (c.nativeAlbumError == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Text('Albums from Nextcloud Photos appear here.'),
            ),
          ),
        if (c.nativeAlbumError case final error?)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: MessageCard(
                message: error,
                isError: true,
                onRetry: c.load,
              ),
            ),
          ),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Row(
            children: [
              Text(
                '${_showNative ? native.length : albums.length} albums',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              if (c.discoveringAlbums && !_showNative)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
      if (_showNative) ...[
        if (native.isEmpty && c.nativeAlbumError == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No Nextcloud albums here yet. Albums from the Nextcloud Photos app appear here with their original membership.',
              ),
            ),
          ),
        _albumCards(nativeCards),
      ],
      if (_showNative && c.nativeAlbumError != null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: MessageCard(
              message: c.nativeAlbumError!,
              isError: true,
              onRetry: c.load,
            ),
          ),
        ),
      if (!_showNative) ...[
        if (albums.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _query.isNotEmpty
                    ? 'No matching Smart albums.'
                    : c.discoveringAlbums
                    ? 'Discovering your photo folders...'
                    : 'No photo albums yet. Choose a photo source in View options.',
              ),
            ),
          ),
        _albumCards(smartCards),
      ],
    ];
  }

  Widget _albumCards(List<_AlbumCard> albums) => SliverPadding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
    sliver: SliverLayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.crossAxisExtent > 650 ? 4 : 2;
        final width =
            (constraints.crossAxisExtent - (columns - 1) * 12) / columns;
        final scale = MediaQuery.textScalerOf(context);
        final infoHeight = (scale.scale(14) + scale.scale(11) * 2) * 1.4 + 16;
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
            mainAxisExtent: width + infoHeight,
          ),
          delegate: SliverChildBuilderDelegate((context, index) {
            final album = albums[index];
            return Semantics(
              button: true,
              label: '${album.name}, ${album.count}',
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: album.open,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: width,
                      width: width,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: _albumArtwork(album),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      album.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (album.subtitle.isNotEmpty)
                      Text(
                        album.subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (album.count.isNotEmpty)
                      Text(album.count, style: const TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            );
          }, childCount: albums.length),
        );
      },
    ),
  );

  List<_AlbumCard> _sharedCards() => c.sharedAlbums
      .where(
        (a) =>
            _query.isEmpty ||
            a.name.toLowerCase().contains(_query.toLowerCase()),
      )
      .map(
        (a) => (
          name: a.name,
          subtitle: 'Shared with you',
          count: '',
          cover: a.files.first,
          open: () {
            setState(_reset);
            if (_scroll.hasClients) _scroll.jumpTo(0);
            c.openSharedAlbum(a.path);
          },
        ),
      )
      .toList();

  List<Widget> _sharedAlbumSlivers() {
    final albums = _sharedCards();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
          child: Text(
            c.loading && albums.isEmpty
                ? 'Loading folders shared with you...'
                : 'Folders others shared with you. Your outgoing shares stay in Drive.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
      if (albums.isEmpty && !c.loading && c.sharedAlbumError == null)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'No shared photo albums here yet. Incoming folders containing photos or videos appear here.',
            ),
          ),
        ),
      _albumCards(albums),
    ];
  }

  Widget _albumContext() {
    final children = <String, List<String>>{};
    for (final file in c.items.where((f) => f.isMedia)) {
      if (file.path.length > c.directory.length + 1) {
        final path = file.path.take(c.directory.length + 1).toList();
        children[path.last] = path;
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${c.items.where((f) => f.isMedia).length} items'
                  '${c.albumIncludesSubfolders ? ', including subfolders' : ', in this folder only'}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
              PopupMenuButton<String>(
                tooltip: 'Album actions',
                onSelected: (action) {
                  if (action == 'drive') {
                    final folder = CloudFile(
                      path: [...c.directory],
                      name: c.directory.lastOrNull ?? 'My drive',
                      isDirectory: true,
                    );
                    setState(_reset);
                    c.openFolder(folder);
                  } else {
                    fileActions(
                      context,
                      c,
                      CloudFile(
                        path: [...c.directory],
                        name: c.directory.last,
                        isDirectory: true,
                      ),
                    );
                  }
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(
                    value: 'drive',
                    child: Text('Open in Drive'),
                  ),
                  if (c.directory.isNotEmpty)
                    const PopupMenuItem(
                      value: 'actions',
                      child: Text('Folder actions'),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (children.isNotEmpty)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Row(
              children: [
                ChoiceChip(
                  label: const Text('All photos'),
                  selected: _subfolder == null,
                  onSelected: (_) => setState(() => _subfolder = null),
                ),
                for (final entry in children.entries)
                  Padding(
                    padding: const EdgeInsets.only(left: 7),
                    child: ChoiceChip(
                      label: Text(entry.key),
                      selected:
                          _subfolder != null &&
                          listPathEquals(_subfolder!, entry.value),
                      onSelected: (_) =>
                          setState(() => _subfolder = entry.value),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Map<String, List<CloudFile>> _memoryGroups(List<CloudFile> files) {
    final now = DateTime.now();
    final result = <String, List<CloudFile>>{};
    for (final file in files) {
      final date = file.timelineDate?.toLocal();
      if (!file.isMedia || date == null || date.year >= now.year) continue;
      if (date.month == now.month && date.day == now.day) {
        final years = now.year - date.year;
        result
            .putIfAbsent(
              years == 1 ? '1 year ago' : '$years years ago',
              () => [],
            )
            .add(file);
      }
    }
    final favorites = files.where((f) => f.isMedia && f.favorite).toList();
    if (favorites.isNotEmpty) result['A few favorites'] = favorites;
    return result;
  }

  Widget _memoryStrip(List<CloudFile> files) => SizedBox(
    height: 124,
    child: ListView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
      children: [
        for (final entry in _memoryGroups(files).entries)
          Padding(
            padding: const EdgeInsets.only(right: 10),
            child: Semantics(
              button: true,
              label: entry.key,
              child: GestureDetector(
                onTap: () => _open(entry.value.first, entry.value),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(15),
                  child: SizedBox(
                    width: 164,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        ExcludeSemantics(
                          child: MediaTile(
                            file: entry.value.first,
                            controller: c,
                          ),
                        ),
                        const DecoratedBox(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.center,
                              end: Alignment.bottomCenter,
                              colors: [Colors.transparent, Colors.black87],
                            ),
                          ),
                        ),
                        Positioned(
                          left: 12,
                          right: 10,
                          bottom: 10,
                          child: Text(
                            entry.key,
                            maxLines: 2,
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );

  /// Whether the full Memories day index can lay out the whole timeline up
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
      _dateStops.clear();
      _rowPositions.clear();
      return [];
    }
    final localizations = MaterialLocalizations.of(context);
    String labelFor(DateTime? date) => date == null
        ? 'Date unavailable'
        : _density >= 5
        ? localizations.formatMonthYear(date)
        : _dayLabel(date);
    final sections =
        <
          ({
            String label,
            DateTime? date,
            List<CloudFile> files,
            List<int> pending,
            List<int> expected,
          })
        >[];
    void addToSection(
      DateTime? date,
      List<CloudFile> files,
      int expected,
      int? pendingDay,
    ) {
      final label = labelFor(date);
      var section = sections.lastOrNull;
      if (section == null || section.label != label) {
        section = (
          label: label,
          date: date,
          files: <CloudFile>[],
          pending: <int>[],
          expected: [0],
        );
        sections.add(section);
      }
      section.files.addAll(files);
      section.expected[0] += expected;
      if (pendingDay != null) section.pending.add(pendingDay);
    }

    if (_indexedLayout) {
      final byDay = <int, List<CloudFile>>{};
      final other = <CloudFile>[];
      for (final file in media) {
        if (file.captureDay case final day?) {
          byDay.putIfAbsent(day, () => []).add(file);
        } else {
          other.add(file);
        }
      }
      for (final day in c.indexedDays) {
        final utc = DateTime.fromMillisecondsSinceEpoch(
          day.id * 86400000,
          isUtc: true,
        );
        final loaded = c.dayLoaded(day.id);
        final found = byDay.remove(day.id) ?? [];
        addToSection(
          DateTime(utc.year, utc.month, utc.day),
          found,
          loaded
              ? found.length
              : (day.count > found.length ? day.count : found.length),
          loaded ? null : day.id,
        );
      }
      for (final file in [...byDay.values.expand((f) => f), ...other]) {
        addToSection(file.timelineDate?.toLocal(), [file], 1, null);
      }
    } else {
      for (final file in media) {
        addToSection(file.timelineDate?.toLocal(), [file], 1, null);
      }
    }
    double? layoutWidth;
    late TimelineGridLayout layout;
    final visibleSections = sections.where((s) => s.expected[0] > 0).toList();
    return [
      SliverLayoutBuilder(
        builder: (context, constraints) {
          _timelineStart = constraints.precedingScrollExtent;
          final columns = constraints.crossAxisExtent > 650
              ? _density + 2
              : _density;
          final tileExtent =
              (constraints.crossAxisExtent - (columns - 1) * 2) / columns;
          final headerExtent =
              44.0 + MediaQuery.textScalerOf(context).scale(13) - 13;
          if (layoutWidth != constraints.crossAxisExtent) {
            layoutWidth = constraints.crossAxisExtent;
            layout = TimelineGridLayout(
              counts: [
                for (final section in visibleSections) section.expected[0],
              ],
              columns: columns,
              tileExtent: tileExtent,
              headerExtent: headerExtent,
              reverseCrossAxis: Directionality.of(context) == TextDirection.rtl,
            );
            _dateStops.clear();
            _rowPositions.clear();
            for (final (index, section) in visibleSections.indexed) {
              _dateStops.add((
                offset: layout.offsets[index],
                label: section.label,
                date: section.date,
              ));
              for (
                var start = 0;
                start < section.files.length;
                start += columns
              ) {
                final end = (start + columns).clamp(0, section.files.length);
                _rowPositions.add((
                  offset:
                      layout.offsets[index] +
                      headerExtent +
                      (start ~/ columns) * (tileExtent + 2),
                  files: section.files.sublist(start, end),
                ));
              }
            }
          }
          final placeholder = Theme.of(
            context,
          ).colorScheme.surfaceContainerHighest;
          return SliverGrid(
            gridDelegate: TimelineGridDelegate(layout),
            delegate: SliverChildBuilderDelegate((context, index) {
              final sectionIndex = layout.sectionForIndex(index);
              final section = visibleSections[sectionIndex];
              final photoIndex = index - layout.starts[sectionIndex] - 1;
              // Request a few sections ahead first so the visible section,
              // requested last, is fetched first.
              for (var next = sectionIndex + 3; next >= sectionIndex; next--) {
                if (next < visibleSections.length &&
                    visibleSections[next].pending.isNotEmpty) {
                  _wantDays(visibleSections[next].pending);
                }
              }
              if (photoIndex < 0) {
                final all = section.files.every(
                  (f) => _selected.containsKey(f.key),
                );
                return Padding(
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          section.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Select ${section.label}',
                        iconSize: 18,
                        onPressed: section.files.every((f) => f.readOnly)
                            ? null
                            : () => setState(() {
                                for (final file in section.files.where(
                                  (f) => !f.readOnly,
                                )) {
                                  if (all) {
                                    _selected.remove(file.key);
                                  } else {
                                    _selected[file.key] = file;
                                  }
                                }
                              }),
                        icon: Icon(
                          all
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                        ),
                      ),
                    ],
                  ),
                );
              }
              return Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: photoIndex < section.files.length
                    ? _mediaTile(section.files[photoIndex], media)
                    : ColoredBox(color: placeholder),
              );
            }, childCount: layout.itemCount),
          );
        },
      ),
    ];
  }

  String _dayLabel(DateTime date) {
    final now = DateTime.now();
    final day = DateTime(date.year, date.month, date.day);
    final today = DateTime(now.year, now.month, now.day);
    if (day == today) return 'Today';
    if (day == today.subtract(const Duration(days: 1))) return 'Yesterday';
    return MaterialLocalizations.of(context).formatMediumDate(date);
  }

  Widget _mediaTile(CloudFile file, List<CloudFile> visible) {
    final selected = _selected.containsKey(file.key);
    return Semantics(
      label: file.name,
      button: true,
      selected: selected,
      child: GestureDetector(
        onTap: () => _open(file, visible),
        onLongPress: file.readOnly ? null : () => _toggle(file),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: EdgeInsets.all(selected ? 6 : 0),
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Hero(
                tag: 'asset:${file.key}',
                child: MediaTile(
                  key: ValueKey(file.key),
                  file: file,
                  controller: c,
                ),
              ),
              if (_selecting && !file.readOnly)
                Positioned(
                  top: 5,
                  left: 5,
                  child: Icon(
                    selected
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    color: selected
                        ? Theme.of(context).colorScheme.primary
                        : Colors.white,
                    size: 22,
                  ),
                ),
              if (file.favorite)
                const Positioned(
                  bottom: 6,
                  right: 6,
                  child: Icon(Icons.favorite, color: Colors.white, size: 14),
                ),
              if (file.isVideo)
                const Positioned(
                  bottom: 5,
                  left: 5,
                  child: Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 21,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _driveSliver(List<CloudFile> files) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    sliver: SliverList.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final colors = Theme.of(context).colorScheme;
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          selected: _selected.containsKey(file.key),
          selectedTileColor: colors.primaryContainer,
          onTap: () => _open(file, files),
          onLongPress: file.readOnly ? null : () => _toggle(file),
          leading: _selecting
              ? Icon(
                  _selected.containsKey(file.key)
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                )
              : SizedBox(
                  width: 40,
                  height: 40,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: file.isMedia
                        ? MediaTile(file: file, controller: c)
                        : ColoredBox(
                            color: colors.surfaceContainerHigh,
                            child: Icon(
                              file.isDirectory
                                  ? Icons.folder_outlined
                                  : Icons.description_outlined,
                              color: colors.primary,
                              size: 22,
                            ),
                          ),
                  ),
                ),
          title: Text(
            file.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          subtitle: Text(
            file.isDirectory ? 'Folder' : formatBytes(file.size),
            style: const TextStyle(fontSize: 11, height: 1.4),
          ),
          trailing: _selecting
              ? null
              : IconButton(
                  tooltip: 'Actions for ${file.name}',
                  onPressed: c.busy
                      ? null
                      : () => fileActions(context, c, file),
                  icon: const Icon(Icons.more_vert, size: 20),
                ),
        );
      },
    ),
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
                ? 'Photos you share from Nextcloud will appear here.'
                : _query.isNotEmpty || _filter != MediaFilter.all
                ? 'Try another search or view option.'
                : 'Add files in Drive to start your collection.',
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );

  Future<void> _viewOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) => SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'View options',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 14),
                if (!_drive && !_albumHome) ...[
                  const Text('Show'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final value in MediaFilter.values)
                        ChoiceChip(
                          label: Text(switch (value) {
                            MediaFilter.all => 'All',
                            MediaFilter.photos => 'Photos',
                            MediaFilter.videos => 'Videos',
                            MediaFilter.favorites => 'Favorites',
                          }),
                          selected: _filter == value,
                          onSelected: (_) {
                            setState(() => _filter = value);
                            update(() {});
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Grid density'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (var value = 2; value <= 6; value++)
                        ChoiceChip(
                          label: Text('$value'),
                          selected: value == _density,
                          onSelected: (_) {
                            _changeDensity(value);
                            update(() {});
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Sort'),
                for (final (value, label) in [
                  (LibrarySort.newest, 'Newest first'),
                  (LibrarySort.oldest, 'Oldest first'),
                  (LibrarySort.name, 'Name A-Z'),
                  if (!_albumHome) (LibrarySort.size, 'Largest first'),
                ])
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(label),
                    trailing: _sort == value ? const Icon(Icons.check) : null,
                    onTap: () {
                      setState(() => _sort = value);
                      update(() {});
                    },
                  ),
                if (_albumHome)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('Choose photo source'),
                    subtitle: Text(
                      'My drive${c.photoRoot.isEmpty ? '' : ' / ${c.photoRoot.join(' / ')}'}',
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _chooseSource();
                    },
                  ),
                if (!_albumHome)
                  Text(
                    c.memoriesAvailable == true
                        ? 'Memories capture dates. Photos load as you scroll.'
                        : 'WebDAV modification dates. Photos load as you scroll.',
                    style: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _selectionBar() => SafeArea(
    top: false,
    child: Material(
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final (action, label, icon) in [
              ('favorite', 'Favorite selected', Icons.favorite_border),
              (
                'move',
                'Move selected to album',
                Icons.drive_file_move_outlined,
              ),
              ('copy', 'Copy selected to album', Icons.copy_outlined),
              ('delete', 'Delete selected', Icons.delete_outline),
            ])
              IconButton(
                tooltip: label,
                onPressed: c.busy ? null : () => _bulk(action),
                icon: Icon(icon),
              ),
            IconButton(
              tooltip: 'Done',
              onPressed: c.busy
                  ? null
                  : () => setState(() => _selected.clear()),
              icon: const Icon(Icons.check),
            ),
          ],
        ),
      ),
    ),
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
      destination = await chooseFolder(context, c, files);
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
          content: Text('Connect Nextcloud to upload your files.'),
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
        if (c.account != account || !listPathEquals(c.directory, destination)) {
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

bool listPathEquals(List<String> a, List<String> b) =>
    a.length == b.length && pathStartsWith(a, b);

/// Google Photos-style fast scroller: a thumb on the right edge that can be
/// dragged across the whole library, with the month under the thumb and year
/// markers along the track. Indexed timelines lay out every day up front, so
/// dragging lands anywhere and the photos there load on demand.
class _TimelineScrubber extends StatefulWidget {
  const _TimelineScrubber({
    required this.controller,
    required this.labelAt,
    required this.markers,
  });

  final ScrollController controller;
  final String? Function(double offset) labelAt;
  final List<({double offset, String label})> Function() markers;

  @override
  State<_TimelineScrubber> createState() => _TimelineScrubberState();
}

class _TimelineScrubberState extends State<_TimelineScrubber> {
  static const _thumbHeight = 48.0;
  bool _active = false;
  bool _dragging = false;
  Timer? _hide;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_scrolled);
  }

  @override
  void didUpdateWidget(_TimelineScrubber oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_scrolled);
      widget.controller.addListener(_scrolled);
    }
  }

  @override
  void dispose() {
    _hide?.cancel();
    widget.controller.removeListener(_scrolled);
    super.dispose();
  }

  void _scrolled() {
    if (!mounted) return;
    setState(() => _active = true);
    _scheduleHide();
  }

  void _scheduleHide() {
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 1600), () {
      if (mounted && !_dragging) setState(() => _active = false);
    });
  }

  void _seek(Offset global, double track) {
    final controller = widget.controller;
    final box = context.findRenderObject() as RenderBox?;
    if (!controller.hasClients || box == null || track <= 0) return;
    final local = box.globalToLocal(global);
    final fraction = ((local.dy - _thumbHeight / 2) / track).clamp(0.0, 1.0);
    controller.jumpTo(fraction * controller.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    if (!controller.hasClients || !controller.position.hasContentDimensions) {
      return const SizedBox.shrink();
    }
    final position = controller.position;
    final max = position.maxScrollExtent;
    if (max < position.viewportDimension * 2) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return LayoutBuilder(
      builder: (context, constraints) {
        final track = constraints.maxHeight - _thumbHeight;
        final fraction = (position.pixels / max).clamp(0.0, 1.0);
        final label = _dragging ? widget.labelAt(position.pixels) : null;
        final visible = _active || _dragging;
        final markers = <Widget>[];
        if (_dragging) {
          var last = -100.0;
          for (final marker in widget.markers()) {
            final top =
                (marker.offset / max).clamp(0.0, 1.0) * track +
                _thumbHeight / 2 -
                8;
            if (top - last < 22) continue;
            last = top;
            markers.add(
              Positioned(
                right: 52,
                top: top,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surface.withValues(alpha: .9),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(marker.label, style: theme.textTheme.labelSmall),
                ),
              ),
            );
          }
        }
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedOpacity(
            opacity: visible ? 1 : 0,
            duration: reduceMotion
                ? Duration.zero
                : const Duration(milliseconds: 180),
            child: Stack(
              children: [
                ...markers,
                Positioned(
                  right: 0,
                  top: fraction * track,
                  height: _thumbHeight,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (label != null)
                        Material(
                          color: theme.colorScheme.inverseSurface,
                          borderRadius: BorderRadius.circular(20),
                          elevation: 3,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 9,
                            ),
                            child: Text(
                              label,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: theme.colorScheme.onInverseSurface,
                              ),
                            ),
                          ),
                        ),
                      Semantics(
                        label: 'Scrub timeline by date',
                        slider: true,
                        child: GestureDetector(
                          key: const ValueKey('timeline-scrubber'),
                          behavior: HitTestBehavior.opaque,
                          onVerticalDragStart: (details) {
                            _hide?.cancel();
                            setState(() => _dragging = true);
                            HapticFeedback.selectionClick();
                          },
                          onVerticalDragUpdate: (details) =>
                              _seek(details.globalPosition, track),
                          onVerticalDragEnd: (_) {
                            setState(() => _dragging = false);
                            _scheduleHide();
                          },
                          onVerticalDragCancel: () {
                            setState(() => _dragging = false);
                            _scheduleHide();
                          },
                          child: SizedBox(
                            width: 48,
                            height: _thumbHeight,
                            child: Center(
                              child: Container(
                                width: 34,
                                height: 44,
                                decoration: BoxDecoration(
                                  color: theme.colorScheme.secondaryContainer,
                                  borderRadius: const BorderRadius.horizontal(
                                    left: Radius.circular(22),
                                  ),
                                  boxShadow: const [
                                    BoxShadow(
                                      blurRadius: 6,
                                      color: Color(0x33000000),
                                    ),
                                  ],
                                ),
                                child: Icon(
                                  Icons.unfold_more,
                                  size: 20,
                                  color: theme.colorScheme.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
