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
  final _floatingDate = ValueNotifier<String?>(null);
  final Map<String, CloudFile> _selected = {};
  final Map<int, Offset> _pointers = {};
  final List<({double offset, String label})> _dateStops = [];
  final List<({double offset, List<CloudFile> files})> _rowPositions = [];
  MediaFilter _filter = MediaFilter.all;
  LibrarySort _sort = LibrarySort.newest;
  List<String>? _group;
  List<String>? _subfolder;
  int _density = 3;
  int _pinchBase = 3;
  double _pinchStart = 0;
  double _timelineStart = 0;
  bool _searching = false;
  bool _showNative = false;
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
  bool get _selecting => _selected.isNotEmpty;
  double get _span => _pointers.length == 2
      ? (_pointers.values.first - _pointers.values.last).distance
      : 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_updateDate);
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    _floatingDate.dispose();
    super.dispose();
  }

  void _updateDate() {
    String? label;
    if (_scroll.hasClients &&
        _scroll.offset > _timelineStart + 80 &&
        !_albumHome &&
        !_drive) {
      for (final stop in _dateStops) {
        if (stop.offset > _scroll.offset - _timelineStart + 56) break;
        label = stop.label;
      }
    }
    _floatingDate.value = label;
  }

  void _reset() {
    _search.clear();
    _selected.clear();
    _query = '';
    _searching = false;
    _showNative = false;
    _filter = MediaFilter.all;
    _group = null;
    _subfolder = null;
    _floatingDate.value = null;
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
    } else if (_album || _collection) {
      _navigate(4);
    } else {
      setState(_reset);
      c.goTo(c.directory.sublist(0, c.directory.length - 1));
      if (_scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  List<CloudFile> get _visible {
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
      final newest = (b.modified ?? DateTime(1970)).compareTo(
        a.modified ?? DateTime(1970),
      );
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
    return files;
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

  void _openSmart(List<String> path) {
    setState(_reset);
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
    final files = _albumHome ? <CloudFile>[] : _visible;
    final theme = Theme.of(context);
    final detail = !_albumHome && (_album || _collection);
    final title =
        c.activeNativeAlbum?.name ??
        (_collection
            ? switch (c.tab) {
                2 => 'Favorites',
                5 => 'Shared',
                _ => 'Offline',
              }
            : _album
            ? (_albumHome ? 'Albums' : c.directory.lastOrNull ?? 'Photos')
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
                  child: CustomScrollView(
                    controller: _scroll,
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      SliverAppBar(
                        floating: true,
                        snap: true,
                        automaticallyImplyLeading: false,
                        leading: _selecting || detail || c.directory.isNotEmpty
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
                      if (c.busy || c.refreshing || c.loadingMore)
                        SliverToBoxAdapter(
                          child: LinearProgressIndicator(
                            minHeight: 2,
                            value: c.busy && c.total > 0
                                ? c.completed / c.total
                                : null,
                          ),
                        ),
                      if (c.error case final error?)
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
                      if (_drive || _albumHome)
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
                                if (_albumHome)
                                  IconButton(
                                    tooltip: 'Choose photo source',
                                    onPressed: c.busy ? null : _chooseSource,
                                    icon: const Icon(
                                      Icons.folder_open_outlined,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      if (_drive && c.directory.isNotEmpty)
                        SliverToBoxAdapter(child: _breadcrumbs()),
                      if (_album && !_albumHome && c.activeNativeAlbum == null)
                        SliverToBoxAdapter(child: _albumContext()),
                      if (c.loading && c.items.isEmpty)
                        const SliverFillRemaining(
                          hasScrollBody: false,
                          child: Center(child: CircularProgressIndicator()),
                        )
                      else if (_albumHome)
                        ..._albumHomeSlivers()
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
                        if (files.isEmpty)
                          SliverFillRemaining(
                            hasScrollBody: false,
                            child: _empty(),
                          ),
                      ],
                      const SliverToBoxAdapter(child: SizedBox(height: 130)),
                    ],
                  ),
                ),
              ),
              if (!_albumHome && !_drive)
                ValueListenableBuilder<String?>(
                  valueListenable: _floatingDate,
                  builder: (context, date, _) => date == null
                      ? const SizedBox.shrink()
                      : Positioned(
                          right: 6,
                          top: 100,
                          child: Row(
                            children: [
                              Material(
                                color: theme.colorScheme.inverseSurface,
                                borderRadius: BorderRadius.circular(20),
                                elevation: 3,
                                child: InkWell(
                                  onTap: _chooseMonth,
                                  borderRadius: BorderRadius.circular(20),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 13,
                                      vertical: 9,
                                    ),
                                    child: Text(
                                      date,
                                      style: TextStyle(
                                        fontSize: 11,
                                        color:
                                            theme.colorScheme.onInverseSurface,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Semantics(
                                label: 'Scrub timeline by date',
                                slider: true,
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onVerticalDragUpdate: (event) {
                                    if (!_scroll.hasClients) return;
                                    final next =
                                        _scroll.offset +
                                        event.delta.dy *
                                            _scroll.position.maxScrollExtent /
                                            220;
                                    _scroll.jumpTo(
                                      next.clamp(
                                        0,
                                        _scroll.position.maxScrollExtent,
                                      ),
                                    );
                                  },
                                  child: SizedBox(
                                    width: 28,
                                    height: 140,
                                    child: Center(
                                      child: Container(
                                        width: 5,
                                        height: 44,
                                        decoration: BoxDecoration(
                                          color: theme.colorScheme.primary,
                                          borderRadius: BorderRadius.circular(
                                            8,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 12),
        child: Material(
          elevation: 8,
          shadowColor: Colors.black26,
          color: colors.surface,
          shape: StadiumBorder(
            side: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .5),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (final (tab, label, icon) in [
                  (0, 'Timeline', Icons.photo_library_outlined),
                  (4, 'Albums', Icons.collections_bookmark_outlined),
                  (1, 'Drive', Icons.folder_outlined),
                ])
                  Flexible(
                    child: Tooltip(
                      message: label,
                      child: Semantics(
                        selected: tab == active,
                        button: true,
                        label: label,
                        excludeSemantics: true,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(28),
                          onTap: c.busy ? null : () => _navigate(tab),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            constraints: const BoxConstraints(
                              minHeight: 46,
                              minWidth: 56,
                            ),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 10,
                            ),
                            decoration: BoxDecoration(
                              color: active == tab
                                  ? colors.primaryContainer
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(28),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  icon,
                                  size: 21,
                                  color: active == tab
                                      ? colors.onPrimaryContainer
                                      : colors.onSurfaceVariant,
                                ),
                                if (active == tab) ...[
                                  const SizedBox(width: 7),
                                  Flexible(
                                    child: Text(
                                      label,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                        color: colors.onPrimaryContainer,
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

  List<Widget> _albumHomeSlivers() {
    final root = c.photoRoot;
    final smartAlbums = c.smartAlbums;
    var albums = smartAlbums
        .where(
          (a) =>
              (_group == null || pathStartsWith(a.path, _group!)) &&
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
    }
    final groups = <String, List<String>>{};
    for (final album in smartAlbums) {
      for (var depth = root.length + 1; depth < album.path.length; depth++) {
        final path = album.path.take(depth).toList();
        groups[path.map(Uri.encodeComponent).join('/')] = path;
      }
    }
    final native = c.nativeAlbums
        .where(
          (a) =>
              _query.isEmpty ||
              a.name.toLowerCase().contains(_query.toLowerCase()),
        )
        .toList();
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 0, 18, 14),
          child: Text(
            'Photo source: My drive${root.isEmpty ? '' : ' / ${root.join(' / ')}'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Row(
            children: [
              for (final (label, icon, tab) in [
                ('Favorites', Icons.favorite_border, 2),
                ('Shared', Icons.people_outline, 5),
                ('Offline', Icons.offline_bolt_outlined, 6),
                ('Recently deleted', Icons.restore_from_trash_outlined, 3),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    avatar: Icon(icon, size: 17),
                    label: Text(label),
                    onPressed: () {
                      if (tab == 3) {
                        Navigator.push(
                          context,
                          MaterialPageRoute<void>(
                            builder: (_) => TrashScreen(controller: c),
                          ),
                        );
                      } else {
                        _navigate(tab);
                      }
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: const Text('Smart albums'),
                selected: !_showNative,
                onSelected: (_) => setState(() => _showNative = false),
              ),
              ChoiceChip(
                label: const Text('Nextcloud albums'),
                selected: _showNative,
                onSelected: (_) => setState(() => _showNative = true),
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
        _albumCards(
          native
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
                    setState(_reset);
                    if (_scroll.hasClients) _scroll.jumpTo(0);
                    c.openNativeAlbum(a);
                  },
                ),
              )
              .toList(),
        ),
      ],
      if (c.nativeAlbumError case final error?)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: MessageCard(message: error, isError: true, onRetry: c.load),
          ),
        ),
      if (!_showNative) ...[
        _section('Your albums', subtitle: 'Across all subfolders'),
        if (groups.isNotEmpty)
          SliverToBoxAdapter(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.only(right: 7),
                    child: ChoiceChip(
                      label: const Text('All'),
                      selected: _group == null,
                      onSelected: (_) => setState(() => _group = null),
                    ),
                  ),
                  for (final path in groups.values)
                    Padding(
                      padding: const EdgeInsets.only(right: 7),
                      child: ChoiceChip(
                        label: Text(path.skip(root.length).join(' / ')),
                        selected:
                            _group != null && listPathEquals(_group!, path),
                        onSelected: (_) => setState(() => _group = path),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (_group != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 12, 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _group!.last,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  TextButton(
                    onPressed: () => _openSmart(_group!),
                    child: const Text('View all photos'),
                  ),
                ],
              ),
            ),
          ),
        if (albums.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                _query.isNotEmpty
                    ? 'No matching Smart albums.'
                    : c.loadingMore
                    ? 'Discovering your photo folders...'
                    : 'No photos or videos in this source. Empty folders stay hidden. Choose another photo source above.',
              ),
            ),
          ),
        _albumCards(
          albums
              .map(
                (a) => (
                  name: listPathEquals(a.path, root)
                      ? 'Photos at root'
                      : a.name,
                  subtitle: a.path.length <= root.length + 1
                      ? ''
                      : a.path
                            .skip(root.length)
                            .take(a.path.length - root.length - 1)
                            .join(' / '),
                  count: '${a.files.length} items',
                  cover: a.files.first,
                  open: () => _openSmart(a.path),
                ),
              )
              .toList(),
        ),
      ],
    ];
  }

  Widget _section(String title, {String? subtitle}) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 18, 12),
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
          if (subtitle != null)
            Flexible(
              child: Text(
                subtitle,
                textAlign: TextAlign.end,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ),
        ],
      ),
    ),
  );

  Widget _albumCards(
    List<
      ({
        String name,
        String subtitle,
        String count,
        CloudFile? cover,
        VoidCallback open,
      })
    >
    albums,
  ) => SliverPadding(
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
                        child: album.cover == null
                            ? ColoredBox(
                                color: Theme.of(
                                  context,
                                ).colorScheme.primaryContainer,
                                child: const Icon(
                                  Icons.photo_album_outlined,
                                  size: 38,
                                ),
                              )
                            : ExcludeSemantics(
                                child: MediaTile(
                                  file: album.cover!,
                                  controller: c,
                                ),
                              ),
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
                  '${c.items.where((f) => f.isMedia).length} items, including subfolders',
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
      final date = file.modified?.toLocal();
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

  List<Widget> _timelineSlivers(List<CloudFile> files) {
    final media = files.where((f) => f.isMedia).toList();
    if (media.isEmpty) {
      _dateStops.clear();
      _rowPositions.clear();
      return [];
    }
    final groups = <String, List<CloudFile>>{};
    for (final file in media) {
      final date = file.modified?.toLocal();
      final label = date == null
          ? 'Date unavailable'
          : _density >= 5
          ? MaterialLocalizations.of(context).formatMonthYear(date)
          : _dayLabel(date);
      groups.putIfAbsent(label, () => []).add(file);
    }
    return [
      SliverLayoutBuilder(
        builder: (context, constraints) {
          _timelineStart = constraints.precedingScrollExtent;
          _dateStops.clear();
          _rowPositions.clear();
          final columns = constraints.crossAxisExtent > 650
              ? _density + 2
              : _density;
          final tileExtent =
              (constraints.crossAxisExtent - (columns - 1) * 2) / columns;
          final headerExtent =
              44.0 + MediaQuery.textScalerOf(context).scale(13) - 13;
          final rows = <({String? label, List<CloudFile> files})>[];
          var offset = 0.0;
          for (final group in groups.entries) {
            _dateStops.add((offset: offset, label: group.key));
            rows.add((label: group.key, files: group.value));
            offset += headerExtent;
            for (var index = 0; index < group.value.length; index += columns) {
              final row = group.value.skip(index).take(columns).toList();
              _rowPositions.add((offset: offset, files: row));
              rows.add((label: null, files: row));
              offset += tileExtent + 2;
            }
          }
          return SliverVariedExtentList.builder(
            itemCount: rows.length,
            itemExtentBuilder: (index, _) => index >= rows.length
                ? null
                : rows[index].label == null
                ? tileExtent + 2
                : headerExtent,
            itemBuilder: (context, index) {
              final row = rows[index];
              if (row.label != null) {
                final all = row.files.every(
                  (f) => _selected.containsKey(f.key),
                );
                return Padding(
                  padding: const EdgeInsets.only(left: 16, right: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          row.label!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        tooltip: 'Select ${row.label}',
                        iconSize: 18,
                        onPressed: row.files.every((f) => f.readOnly)
                            ? null
                            : () => setState(() {
                                for (final file in row.files.where(
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
                child: Row(
                  children: [
                    for (var i = 0; i < columns; i++) ...[
                      if (i > 0) const SizedBox(width: 2),
                      Expanded(
                        child: i < row.files.length
                            ? _mediaTile(row.files[i], media)
                            : const SizedBox.shrink(),
                      ),
                    ],
                  ],
                ),
              );
            },
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
            c.error != null ? 'Connection interrupted' : 'Nothing here yet',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 10),
          Text(
            c.error != null
                ? 'Your loaded items are kept. Pull to refresh and retry.'
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
                  (LibrarySort.newest, 'Newest modified first'),
                  (LibrarySort.oldest, 'Oldest modified first'),
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
                if (!_drive && !_albumHome)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.calendar_month_outlined),
                    title: const Text('Jump to month'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _chooseMonth();
                    },
                  ),
                if (_albumHome)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('Choose photo source'),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      _chooseSource();
                    },
                  ),
                const Text(
                  'Timeline dates currently use file modification time.',
                  style: TextStyle(fontSize: 11),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _chooseMonth() async {
    final labels = _dateStops.map((s) => s.label).toList();
    final monthDates =
        _visible
            .map((f) => f.modified?.toLocal())
            .nonNulls
            .map((d) => DateTime(d.year, d.month))
            .toSet()
            .toList()
          ..sort((a, b) => b.compareTo(a));
    final month = await showModalBottomSheet<DateTime>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(title: Text('Jump to month')),
            for (final date in monthDates)
              ListTile(
                title: Text(
                  MaterialLocalizations.of(context).formatMonthYear(date),
                ),
                onTap: () => Navigator.pop(context, date),
              ),
          ],
        ),
      ),
    );
    if (!mounted || month == null || !_scroll.hasClients) return;
    final candidates = c.items.where((f) {
      final d = f.modified?.toLocal();
      return d?.year == month.year && d?.month == month.month;
    }).toList();
    if (candidates.isEmpty) return;
    final label = _density >= 5
        ? MaterialLocalizations.of(context).formatMonthYear(month)
        : labels.firstWhere(
            (label) => candidates.any(
              (f) => _dayLabel(f.modified!.toLocal()) == label,
            ),
            orElse: () => '',
          );
    final stop = _dateStops.where((s) => s.label == label).firstOrNull;
    if (stop != null) {
      _scroll.jumpTo(
        (_timelineStart + stop.offset).clamp(
          0,
          _scroll.position.maxScrollExtent,
        ),
      );
      _updateDate();
    }
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
