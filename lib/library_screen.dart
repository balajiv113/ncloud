import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_controller.dart';
import 'asset_viewer.dart';
import 'library_actions.dart';
import 'media_tile.dart';
import 'models.dart';
import 'screens.dart';

enum MediaFilter { all, photos, videos, favorites }

enum LibrarySort { newest, oldest, name, size }

class LibraryScreen extends StatefulWidget {
  const LibraryScreen({super.key, required this.controller});
  final AppController controller;
  @override
  State<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends State<LibraryScreen> {
  final _search = TextEditingController();
  final _scroll = ScrollController();
  final Map<String, CloudFile> _selected = {};
  MediaFilter _filter = MediaFilter.all;
  LibrarySort _sort = LibrarySort.newest;
  DateTime? _month;
  int _density = 3;
  int _pinchBase = 3;
  double _pinchStart = 0;
  final Map<int, Offset> _pointers = {};
  double get _span => _pointers.length == 2
      ? (_pointers.values.first - _pointers.values.last).distance
      : 0;
  bool _searching = false;
  String _query = '';
  AppController get c => widget.controller;
  bool get _album => c.tab == 4;
  bool get _drive => c.tab == 1;
  bool get _library => c.tab == 2;
  bool get _selecting => _selected.isNotEmpty;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _reset() {
    _search.clear();
    _selected.clear();
    _query = '';
    _month = null;
    _filter = MediaFilter.all;
  }

  List<CloudFile> get _visible {
    final files = c.items.where((f) {
      if (_query.isNotEmpty &&
          !f.name.toLowerCase().contains(_query.toLowerCase())) {
        return false;
      }
      if (f.isDirectory) return _album || _drive || _library;
      if (_album && !f.isMedia) return false;
      final date = f.modified?.toLocal();
      if (_month != null &&
          (date == null ||
              date.year != _month!.year ||
              date.month != _month!.month)) {
        return false;
      }
      return switch (_filter) {
        MediaFilter.all => true,
        MediaFilter.photos => f.isImage,
        MediaFilter.videos => f.isVideo,
        MediaFilter.favorites => f.favorite,
      };
    }).toList();
    files.sort((a, b) {
      if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
      final newest = (b.modified ?? DateTime(1970)).compareTo(
        a.modified ?? DateTime(1970),
      );
      final comparison = switch (_sort) {
        LibrarySort.newest => newest,
        LibrarySort.oldest => -newest,
        LibrarySort.name => a.name.toLowerCase().compareTo(
          b.name.toLowerCase(),
        ),
        LibrarySort.size => b.size.compareTo(a.size),
      };
      return comparison == 0 ? a.key.compareTo(b.key) : comparison;
    });
    return files;
  }

  void _toggle(CloudFile file) {
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
      return;
    }
    if (file.isDirectory) {
      setState(_reset);
      c.openFolder(file);
      if (_scroll.hasClients) _scroll.jumpTo(0);
    } else if (file.isMedia) {
      final media = visible.where((f) => f.isMedia).toList();
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => AssetViewer(
            files: media,
            initialIndex: media.indexWhere((f) => f.key == file.key),
            controller: c,
          ),
        ),
      );
    } else {
      fileActions(context, c, file);
    }
  }

  @override
  Widget build(BuildContext context) {
    final files = _visible;
    final theme = Theme.of(context);
    final title = _album
        ? (c.directory.isEmpty ? 'Albums' : c.directory.last)
        : _drive
        ? (c.directory.isEmpty ? 'Drive' : c.directory.last)
        : _library
        ? 'Library'
        : 'Your timeline';
    return PopScope(
      canPop: !_selecting && c.directory.isEmpty && !c.busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop || c.busy) return;
        if (_selecting) {
          setState(() => _selected.clear());
        } else if (c.directory.isNotEmpty) {
          setState(_reset);
          c.goTo(c.directory.sublist(0, c.directory.length - 1));
        }
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: RefreshIndicator(
            onRefresh: () async {
              setState(() => _selected.clear());
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
                if (_pointers.length != 2 || _drive || _library) return;
                if (_pinchStart <= 0) return;
                final scale = _span / _pinchStart;
                final next = scale > 1.3
                    ? (_pinchBase - 1).clamp(2, 6).toInt()
                    : scale < 0.75
                    ? (_pinchBase + 1).clamp(2, 6).toInt()
                    : _density;
                if (next != _density) {
                  HapticFeedback.selectionClick();
                  setState(() => _density = next);
                }
              },
              onPointerUp: (event) => _pointers.remove(event.pointer),
              onPointerCancel: (event) => _pointers.remove(event.pointer),
              child: Scrollbar(
                controller: _scroll,
                interactive: true,
                thickness: 6,
                radius: const Radius.circular(8),
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    SliverAppBar(
                      pinned: true,
                      automaticallyImplyLeading: false,
                      title: _selecting
                          ? Text('${_selected.length} selected')
                          : Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.all_inclusive_rounded,
                                  color: theme.colorScheme.primary,
                                  size: 30,
                                ),
                                const SizedBox(width: 8),
                                const Flexible(
                                  child: Text(
                                    'ncloud',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -1,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                      leading: _selecting
                          ? IconButton(
                              tooltip: 'Cancel selection',
                              onPressed: () =>
                                  setState(() => _selected.clear()),
                              icon: const Icon(Icons.close),
                            )
                          : c.directory.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Parent folder',
                              icon: const Icon(Icons.arrow_back),
                              onPressed: () {
                                setState(_reset);
                                c.goTo(
                                  c.directory.sublist(
                                    0,
                                    c.directory.length - 1,
                                  ),
                                );
                              },
                            ),
                      actions: [
                        if (c.demo && !_selecting)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 18),
                            child: Text(
                              'DEMO',
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.5,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        IconButton(
                          tooltip: 'Search loaded items',
                          icon: Icon(
                            _searching ? Icons.search_off : Icons.search,
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
                          tooltip: 'Settings',
                          onPressed: () => Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => SettingsScreen(controller: c),
                            ),
                          ),
                          icon: CircleAvatar(
                            radius: 16,
                            backgroundColor: theme.colorScheme.primaryContainer,
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
                                fontWeight: FontWeight.w700,
                                fontSize: 12,
                                color: theme.colorScheme.primary,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _album
                                  ? 'LIFE, ORGANIZED'
                                  : _drive
                                  ? 'ROOM FOR EVERYTHING'
                                  : _library
                                  ? 'KEEP IT CLOSE'
                                  : 'THE EVERYDAY & THE EXTRAORDINARY',
                              style: theme.textTheme.labelSmall?.copyWith(
                                letterSpacing: 2,
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.headlineLarge
                                        ?.copyWith(
                                          letterSpacing: -1.5,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                                if (!_drive && !_library)
                                  IconButton(
                                    tooltip: 'Grid density',
                                    onPressed: () => setState(
                                      () => _density = _density >= 4
                                          ? 2
                                          : _density + 1,
                                    ),
                                    icon: Icon(
                                      _density == 3
                                          ? Icons.grid_view_rounded
                                          : Icons.grid_on_rounded,
                                    ),
                                  ),
                                PopupMenuButton<LibrarySort>(
                                  tooltip: 'Sort items',
                                  initialValue: _sort,
                                  icon: const Icon(Icons.sort),
                                  onSelected: (value) =>
                                      setState(() => _sort = value),
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                      value: LibrarySort.newest,
                                      child: Text('Newest modified first'),
                                    ),
                                    PopupMenuItem(
                                      value: LibrarySort.oldest,
                                      child: Text('Oldest modified first'),
                                    ),
                                    PopupMenuItem(
                                      value: LibrarySort.name,
                                      child: Text('Name A–Z'),
                                    ),
                                    PopupMenuItem(
                                      value: LibrarySort.size,
                                      child: Text('Largest first'),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _album
                                  ? 'Real folders. Beautiful collections.'
                                  : _drive
                                  ? 'Your files, without the noise.'
                                  : _library
                                  ? 'Favorites, shared moments & second chances.'
                                  : 'A home for the moments that make you, you.',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                            if (_searching)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: TextField(
                                  controller: _search,
                                  autofocus: true,
                                  onChanged: (value) =>
                                      setState(() => _query = value),
                                  decoration: InputDecoration(
                                    hintText: _drive
                                        ? 'Filter this folder'
                                        : 'Filter loaded items',
                                    prefixIcon: const Icon(Icons.search),
                                    suffixIcon: IconButton(
                                      tooltip: 'Clear search',
                                      onPressed: () => setState(() {
                                        _query = '';
                                        _search.clear();
                                      }),
                                      icon: const Icon(Icons.close),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                    if (c.busy)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: Column(
                            children: [
                              LinearProgressIndicator(
                                value: c.total > 0
                                    ? c.completed / c.total
                                    : null,
                              ),
                              const SizedBox(height: 8),
                              const Text(
                                'Working · keep ncloud open',
                                style: TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (c.error case final error?)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: MessageCard(
                            message: error,
                            isError: true,
                            onRetry: c.loading || c.busy ? null : c.load,
                          ),
                        ),
                      ),
                    if (c.notice case final notice?)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                            vertical: 8,
                          ),
                          child: Text(
                            notice,
                            style: TextStyle(color: theme.colorScheme.primary),
                          ),
                        ),
                      ),
                    if (_album || _drive)
                      SliverToBoxAdapter(child: _breadcrumbs()),
                    if (_library)
                      SliverToBoxAdapter(child: _libraryShortcuts()),
                    if (!_drive && !_library)
                      SliverToBoxAdapter(child: _filters()),
                    if (!_drive && !_album)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: Text(
                            c.demo
                                ? 'Original demo illustrations · changes are temporary'
                                : '${c.items.length} loaded${c.hasMore ? ' · more available below' : ''} · modification dates',
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ),
                    if (c.refreshing)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      ),
                    if (c.loading && !c.refreshing)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else ...[
                      if (!_drive &&
                          !_library &&
                          c.directory.isEmpty &&
                          !_selecting &&
                          _query.isEmpty &&
                          _filter == MediaFilter.all &&
                          _month == null &&
                          c.tab == 0 &&
                          files.isNotEmpty)
                        SliverToBoxAdapter(child: _spotlight(files)),
                      if (!_drive &&
                          !_library &&
                          !_album &&
                          !_selecting &&
                          _query.isEmpty &&
                          _month == null &&
                          _memories(files).isNotEmpty)
                        SliverToBoxAdapter(child: _memoryStrip(files)),
                      if (_album)
                        ..._albumSlivers(files)
                      else if (_drive || _library)
                        _driveSliver(files)
                      else
                        ..._timelineSlivers(files),
                      if (files.isEmpty)
                        SliverFillRemaining(
                          hasScrollBody: false,
                          child: _empty(),
                        ),
                      if (c.hasMore)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 24,
                              vertical: 24,
                            ),
                            child: OutlinedButton.icon(
                              onPressed: c.loadingMore || c.busy
                                  ? null
                                  : c.loadMore,
                              icon: c.loadingMore
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.expand_more),
                              label: Text(
                                c.loadingMore
                                    ? 'Loading earlier moments…'
                                    : 'Load more from Nextcloud',
                              ),
                            ),
                          ),
                        ),
                      const SliverToBoxAdapter(child: SizedBox(height: 100)),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        floatingActionButton: (_album || _drive) && !_selecting
            ? FloatingActionButton(
                tooltip: _album ? 'Add to album' : 'Add files',
                onPressed: c.busy ? null : _add,
                child: const Icon(Icons.add),
              )
            : null,
        bottomNavigationBar: _selecting
            ? _selectionBar()
            : NavigationBar(
                selectedIndex: const [0, 4, 1, 2].indexOf(c.tab).clamp(0, 3),
                onDestinationSelected: (index) {
                  setState(_reset);
                  c.selectTab(const [0, 4, 1, 2][index]);
                  if (_scroll.hasClients) _scroll.jumpTo(0);
                },
                destinations: const [
                  NavigationDestination(
                    icon: Icon(Icons.photo_library_outlined),
                    selectedIcon: Icon(Icons.photo_library_rounded),
                    label: 'Timeline',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.collections_bookmark_outlined),
                    selectedIcon: Icon(Icons.collections_bookmark_rounded),
                    label: 'Albums',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.folder_outlined),
                    selectedIcon: Icon(Icons.folder_rounded),
                    label: 'Drive',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.space_dashboard_outlined),
                    selectedIcon: Icon(Icons.space_dashboard_rounded),
                    label: 'Library',
                  ),
                ],
              ),
      ),
    );
  }

  Widget _filters() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    child: Row(
      children: [
        for (final (value, label, icon) in [
          (MediaFilter.all, 'All', Icons.apps_rounded),
          (MediaFilter.photos, 'Photos', Icons.image_outlined),
          (MediaFilter.videos, 'Videos', Icons.videocam_outlined),
          (MediaFilter.favorites, 'Favorites', Icons.favorite_border),
        ])
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              selected: _filter == value,
              showCheckmark: false,
              avatar: Icon(icon, size: 16),
              label: Text(label),
              onSelected: (_) => setState(() => _filter = value),
            ),
          ),
        if (c.tab == 0)
          ActionChip(
            avatar: const Icon(Icons.calendar_month_outlined, size: 16),
            label: Text(
              _month == null
                  ? 'By month'
                  : MaterialLocalizations.of(context).formatMonthYear(_month!),
            ),
            onPressed: _chooseMonth,
          ),
        if (_month != null)
          IconButton(
            tooltip: 'All dates',
            onPressed: () => setState(() => _month = null),
            icon: const Icon(Icons.close),
          ),
      ],
    ),
  );

  Future<void> _chooseMonth() async {
    final months =
        c.items
            .map((f) => f.modified?.toLocal())
            .nonNulls
            .map((d) => DateTime(d.year, d.month))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    final value = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Jump to a loaded month'),
              subtitle: Text(
                'Load more timeline pages to include earlier dates.',
              ),
            ),
            for (final month in months)
              ListTile(
                leading: const Icon(Icons.calendar_today_outlined),
                title: Text(
                  MaterialLocalizations.of(context).formatMonthYear(month),
                ),
                onTap: () => Navigator.pop(context, month),
              ),
          ],
        ),
      ),
    );
    if (mounted && value != null) {
      setState(() => _month = value);
      _scroll.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }
  }

  Widget _breadcrumbs() => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    child: Row(
      children: [
        TextButton.icon(
          onPressed: () {
            setState(_reset);
            c.goTo([]);
          },
          icon: Icon(
            _album ? Icons.collections_bookmark_outlined : Icons.home_outlined,
            size: 16,
          ),
          label: Text(_album ? 'All albums' : 'All files'),
        ),
        for (var i = 0; i < c.directory.length; i++) ...[
          const Icon(Icons.chevron_right, size: 14),
          TextButton(
            onPressed: () {
              final path = c.directory.take(i + 1).toList();
              setState(_reset);
              c.goTo(path);
            },
            child: Text(c.directory[i]),
          ),
        ],
      ],
    ),
  );

  Widget _libraryShortcuts() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Card(
          margin: EdgeInsets.zero,
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 20,
              vertical: 10,
            ),
            leading: const Icon(Icons.restore_from_trash_outlined),
            title: const Text('Recently deleted'),
            subtitle: const Text('Give a moment a second chance'),
            trailing: const Icon(Icons.arrow_forward_rounded),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TrashScreen(controller: c),
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'Your favorites',
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ],
    ),
  );

  Widget _spotlight(List<CloudFile> files) {
    final file = files.firstWhere((f) => f.isMedia);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: GestureDetector(
        onTap: () => _open(file, files),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(28),
          child: SizedBox(
            height: 210,
            child: Stack(
              fit: StackFit.expand,
              children: [
                ExcludeSemantics(
                  child: MediaTile(file: file, controller: c),
                ),
                const DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.black12, Colors.black87],
                    ),
                  ),
                ),
                const Positioned(
                  top: 20,
                  left: 20,
                  child: Text(
                    'RECENT HIGHLIGHT',
                    style: TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      letterSpacing: 2.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Positioned(
                  bottom: 24,
                  left: 20,
                  right: 20,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      const Expanded(
                        child: Text(
                          'The good\nin the everyday.',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 29,
                            height: 1.05,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -.8,
                          ),
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: const BoxDecoration(
                          color: Colors.white24,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.arrow_outward,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Photos taken on this calendar day in earlier years, grouped by year.
  Map<int, List<CloudFile>> _memories(List<CloudFile> files) {
    final now = DateTime.now();
    final years = <int, List<CloudFile>>{};
    for (final file in files) {
      final date = file.modified?.toLocal();
      if (!file.isMedia || date == null || date.year >= now.year) continue;
      if (date.month == now.month && (date.day - now.day).abs() <= 1) {
        years.putIfAbsent(date.year, () => []).add(file);
      }
    }
    return Map.fromEntries(
      years.entries.toList()..sort((a, b) => b.key.compareTo(a.key)),
    );
  }

  Widget _memoryStrip(List<CloudFile> files) {
    final memories = _memories(files);
    final now = DateTime.now().year;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
          child: Text(
            'On this day',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ),
        SizedBox(
          height: 168,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final entry in memories.entries)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Semantics(
                    button: true,
                    label:
                        '${now - entry.key} years ago, ${entry.value.length} items',
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AssetViewer(
                            files: entry.value,
                            initialIndex: 0,
                            controller: c,
                          ),
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(18),
                        child: SizedBox(
                          width: 120,
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
                                    colors: [
                                      Colors.transparent,
                                      Colors.black87,
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 12,
                                right: 12,
                                bottom: 12,
                                child: ExcludeSemantics(
                                  child: Text(
                                    now - entry.key == 1
                                        ? '1 year ago'
                                        : '${now - entry.key} years ago',
                                    maxLines: 2,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                    ),
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
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  List<Widget> _timelineSlivers(List<CloudFile> files) {
    final groups = <String, List<CloudFile>>{};
    for (final file in files.where((f) => f.isMedia)) {
      final date = file.modified?.toLocal();
      final label = date == null ? 'Date unavailable' : _dayLabel(date);
      groups.putIfAbsent(label, () => []).add(file);
    }
    return [
      for (final group in groups.entries) ...[
        SliverPersistentHeader(
          pinned: true,
          delegate: _DateHeader(
            title: group.key,
            count: group.value.length,
            selected: group.value.every((f) => _selected.containsKey(f.key)),
            onSelect: () => setState(() {
              final all = group.value.every(
                (f) => _selected.containsKey(f.key),
              );
              for (final file in group.value) {
                if (all) {
                  _selected.remove(file.key);
                } else {
                  _selected[file.key] = file;
                }
              }
            }),
            color: Theme.of(context).scaffoldBackgroundColor,
          ),
        ),
        _mediaGrid(group.value, files),
      ],
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

  Widget _mediaGrid(List<CloudFile> media, List<CloudFile> visible) =>
      SliverPadding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        sliver: SliverLayoutBuilder(
          builder: (context, constraints) {
            final columns = (constraints.crossAxisExtent > 600
                ? _density + 2
                : _density);
            return SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: columns,
                crossAxisSpacing: 3,
                mainAxisSpacing: 3,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final file = media[index];
                final selected = _selected.containsKey(file.key);
                return Semantics(
                  label: file.name,
                  button: true,
                  selected: selected,
                  child: GestureDetector(
                    onTap: () => _open(file, visible),
                    onLongPress: () => _toggle(file),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      padding: EdgeInsets.all(selected ? 7 : 0),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(selected ? 20 : 6),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(selected ? 12 : 6),
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
                            if (_selecting)
                              Positioned(
                                top: 6,
                                left: 6,
                                child: Icon(
                                  selected
                                      ? Icons.check_circle
                                      : Icons.radio_button_unchecked,
                                  color: selected
                                      ? Theme.of(context).colorScheme.primary
                                      : Colors.white,
                                ),
                              ),
                            if (file.favorite)
                              const Positioned(
                                bottom: 8,
                                right: 8,
                                child: Icon(
                                  Icons.favorite,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              ),
                            if (file.isVideo)
                              const Positioned(
                                bottom: 8,
                                left: 8,
                                child: Icon(
                                  Icons.play_circle_fill_rounded,
                                  color: Colors.white,
                                  size: 22,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }, childCount: media.length),
            );
          },
        ),
      );

  List<Widget> _albumSlivers(List<CloudFile> files) {
    final folders = files.where((f) => f.isDirectory).toList();
    final media = files.where((f) => f.isMedia).toList();
    return [
      if (folders.isNotEmpty)
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          sliver: SliverLayoutBuilder(
            builder: (context, constraints) => SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: constraints.crossAxisExtent > 650 ? 4 : 2,
                mainAxisSpacing: 20,
                crossAxisSpacing: 16,
                childAspectRatio: .8,
              ),
              delegate: SliverChildBuilderDelegate((context, index) {
                final folder = folders[index];
                return GestureDetector(
                  onTap: () => _open(folder, files),
                  onLongPress: () => _toggle(folder),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(22),
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AlbumCover(folder: folder, controller: c),
                              const DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Colors.transparent,
                                      Colors.black26,
                                    ],
                                  ),
                                ),
                              ),
                              Positioned(
                                top: 8,
                                right: 8,
                                child: _selecting
                                    ? Icon(
                                        _selected.containsKey(folder.key)
                                            ? Icons.check_circle
                                            : Icons.radio_button_unchecked,
                                        color: Colors.white,
                                      )
                                    : IconButton.filledTonal(
                                        tooltip: 'Actions for ${folder.name}',
                                        onPressed: c.busy
                                            ? null
                                            : () => fileActions(
                                                context,
                                                c,
                                                folder,
                                              ),
                                        icon: const Icon(
                                          Icons.more_horiz,
                                          size: 18,
                                        ),
                                      ),
                              ),
                              const Positioned(
                                bottom: 12,
                                left: 12,
                                child: Icon(
                                  Icons.folder_outlined,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Text(
                        folder.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        'Folder album',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                );
              }, childCount: folders.length),
            ),
          ),
        ),
      if (media.isNotEmpty) ..._timelineSlivers(media),
    ];
  }

  Widget _driveSliver(List<CloudFile> files) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 16),
    sliver: SliverList.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        return Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: ListTile(
            selected: _selected.containsKey(file.key),
            selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(18),
            ),
            onTap: () => _open(file, files),
            onLongPress: () => _toggle(file),
            leading: _selecting
                ? Icon(
                    _selected.containsKey(file.key)
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                  )
                : file.isMedia
                ? SizedBox(
                    width: 48,
                    height: 48,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: MediaTile(file: file, controller: c),
                    ),
                  )
                : Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: Icon(
                      file.isDirectory
                          ? Icons.folder_rounded
                          : Icons.description_outlined,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
            title: Text(
              file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            subtitle: Text(
              file.isDirectory ? 'Folder' : formatBytes(file.size),
            ),
            trailing: _selecting
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (file.favorite)
                        Icon(
                          Icons.favorite,
                          size: 14,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      IconButton(
                        tooltip: 'Actions for ${file.name}',
                        onPressed: c.busy
                            ? null
                            : () => fileActions(context, c, file),
                        icon: const Icon(Icons.more_horiz),
                      ),
                    ],
                  ),
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
            c.error == null
                ? _album
                      ? Icons.collections_bookmark_outlined
                      : _library
                      ? Icons.favorite_border
                      : Icons.photo_library_outlined
                : Icons.cloud_off,
            size: 52,
            color: Theme.of(context).colorScheme.primary,
          ),
          const SizedBox(height: 20),
          Text(
            c.error != null
                ? 'A little connection trouble'
                : _query.isNotEmpty ||
                      _month != null ||
                      _filter != MediaFilter.all
                ? 'Nothing here just yet'
                : _album
                ? 'A collection starts with a folder'
                : _library
                ? 'Keep your favorites close'
                : 'Make room for something good',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          Text(
            c.error != null
                ? 'Refresh to try again.'
                : _album
                ? 'Folders become albums automatically. Add a folder or open one to see its photos.'
                : 'Try another filter, load older pages, or add files from Drive.',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    ),
  );

  Widget _selectionBar() => SafeArea(
    top: false,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      color: Theme.of(context).colorScheme.surfaceContainer,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          IconButton(
            tooltip: 'Favorite selected',
            onPressed: c.busy ? null : () => _bulk('favorite'),
            icon: const Icon(Icons.favorite_border),
          ),
          IconButton(
            tooltip: 'Move selected to album',
            onPressed: c.busy ? null : () => _bulk('move'),
            icon: const Icon(Icons.drive_file_move_outlined),
          ),
          IconButton(
            tooltip: 'Copy selected to album',
            onPressed: c.busy ? null : () => _bulk('copy'),
            icon: const Icon(Icons.copy_outlined),
          ),
          IconButton(
            tooltip: 'Delete selected',
            onPressed: c.busy ? null : () => _bulk('delete'),
            icon: const Icon(Icons.delete_outline),
          ),
          TextButton(
            onPressed: c.busy ? null : () => setState(() => _selected.clear()),
            child: const Text('Done'),
          ),
        ],
      ),
    ),
  );

  Future<void> _bulk(String operation) async {
    // A selected folder already includes its descendants.
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
              subtitle: Text(
                c.directory.isEmpty
                    ? 'Destination: Nextcloud root'
                    : 'Destination: /${c.directory.join('/')}',
              ),
              onTap: () => Navigator.pop(context, 'upload'),
            ),
            ListTile(
              leading: const Icon(Icons.create_new_folder_outlined),
              title: Text(_album ? 'New album folder' : 'New folder'),
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
        builder: (_) =>
            NameDialog(title: _album ? 'New album folder' : 'New folder'),
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
        if (c.account != account ||
            !pathStartsWith(c.directory, destination) ||
            c.directory.length != destination.length) {
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

class AlbumCover extends StatefulWidget {
  const AlbumCover({super.key, required this.folder, required this.controller});
  final CloudFile folder;
  final AppController controller;
  @override
  State<AlbumCover> createState() => _AlbumCoverState();
}

class _AlbumCoverState extends State<AlbumCover> {
  late Future<CloudFile?> _cover = widget.controller.albumCover(widget.folder);
  @override
  void didUpdateWidget(AlbumCover oldWidget) {
    super.didUpdateWidget(oldWidget);
    _cover = widget.controller.albumCover(widget.folder);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<CloudFile?>(
    future: _cover,
    builder: (context, snapshot) {
      if (snapshot.data case final photo?) {
        return MediaTile(file: photo, controller: widget.controller);
      }
      final colors = Theme.of(context).colorScheme;
      return Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [colors.primaryContainer, colors.tertiaryContainer],
          ),
        ),
        child: Center(
          child: snapshot.hasError
              ? IconButton(
                  tooltip: 'Cover unavailable. Retry',
                  icon: const Icon(Icons.refresh),
                  onPressed: () => setState(() {
                    _cover = widget.controller
                        .folderContents(widget.folder.path)
                        .then(
                          (files) => files.where((f) => f.isMedia).firstOrNull,
                        );
                  }),
                )
              : Icon(
                  Icons.collections_outlined,
                  size: 48,
                  color: colors.primary.withValues(alpha: .5),
                ),
        ),
      );
    },
  );
}

class _DateHeader extends SliverPersistentHeaderDelegate {
  _DateHeader({
    required this.title,
    required this.count,
    required this.selected,
    required this.onSelect,
    required this.color,
  });
  final String title;
  final int count;
  final bool selected;
  final VoidCallback onSelect;
  final Color color;
  @override
  double get minExtent => 54;
  @override
  double get maxExtent => 54;
  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => SizedBox(
    height: maxExtent,
    child: ColoredBox(
      color: color,
      child: Padding(
        padding: const EdgeInsets.only(left: 20, right: 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            Text('$count', style: Theme.of(context).textTheme.labelSmall),
            IconButton(
              tooltip: 'Select $title',
              onPressed: onSelect,
              icon: Icon(
                selected ? Icons.check_circle : Icons.radio_button_unchecked,
                size: 19,
              ),
            ),
          ],
        ),
      ),
    ),
  );
  @override
  bool shouldRebuild(_DateHeader oldDelegate) => true;
}
