import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ui/messages.dart';
import '../../discovery_models.dart';
import '../../models.dart';
import '../../shared/ui/media_tile.dart';
import '../photos/people_bubble.dart';
import 'domain/library_view.dart';

/// One album as shown on a card: its title, subtitle, cover and open action.
typedef AlbumCard = ({
  String name,
  String subtitle,
  String count,
  CloudFile? cover,
  VoidCallback open,
});

/// How the album home asks the screen to navigate; the screen also resets its
/// own view state and scroll position.
class AlbumHomeActions {
  const AlbumHomeActions({
    required this.openSmart,
    required this.openNative,
    required this.openShared,
    required this.openPerson,
    required this.expandAlbums,
    required this.expandPeople,
    required this.openMap,
    required this.openCollection,
  });

  final void Function(List<String> path) openSmart;
  final void Function(CloudAlbum album) openNative;
  final void Function(List<String> path) openShared;
  final void Function(RecognizedPerson person) openPerson;
  final void Function(bool native) expandAlbums;
  final VoidCallback expandPeople;
  final VoidCallback openMap;
  final void Function(int tab) openCollection;
}

/// The Albums destination: pinned collections, Smart albums, People, Map,
/// shared folders and cloud albums, or one of those sections expanded.
class AlbumHomeSlivers extends StatelessWidget {
  const AlbumHomeSlivers({
    super.key,
    required this.controller,
    required this.query,
    required this.sort,
    required this.expanded,
    required this.showNative,
    required this.showPeople,
    required this.actions,
  });

  final AppController controller;
  final String query;
  final LibrarySort sort;
  final bool expanded;
  final bool showNative;
  final bool showPeople;
  final AlbumHomeActions actions;

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: _AlbumSections(
      context: context,
      c: controller,
      query: query,
      sort: sort,
      expanded: expanded,
      showNative: showNative,
      showPeople: showPeople,
      actions: actions,
    ).home(),
  );
}

/// Folders other people shared with this account, as album cards.
class SharedAlbumSlivers extends StatelessWidget {
  const SharedAlbumSlivers({
    super.key,
    required this.controller,
    required this.query,
    required this.actions,
  });

  final AppController controller;
  final String query;
  final AlbumHomeActions actions;

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: _AlbumSections(
      context: context,
      c: controller,
      query: query,
      sort: LibrarySort.newest,
      expanded: false,
      showNative: false,
      showPeople: false,
      actions: actions,
    ).shared(),
  );
}

class _AlbumSections {
  const _AlbumSections({
    required this.context,
    required this.c,
    required this.query,
    required this.sort,
    required this.expanded,
    required this.showNative,
    required this.showPeople,
    required this.actions,
  });

  final BuildContext context;
  final AppController c;
  final String query;
  final LibrarySort sort;
  final bool expanded;
  final bool showNative;
  final bool showPeople;
  final AlbumHomeActions actions;

  List<Widget> _peopleSlivers({bool expanded = false}) {
    final people = c.people
        .where((p) => p.label.toLowerCase().contains(query.toLowerCase()))
        .toList();
    final height =
        (expanded ? 124 : 100) +
        MediaQuery.textScalerOf(context).scale(14) * 1.5 +
        MediaQuery.textScalerOf(context).scale(12) * 1.5;
    Widget bubble(int index) => PeopleBubble(
      key: ValueKey('person-${people[index].id}'),
      person: people[index],
      controller: c,
      diameter: expanded ? 96 : 72,
      onTap: () => actions.openPerson(people[index]),
    );
    return [
      if (!expanded)
        _albumSectionHeading('People', expand: actions.expandPeople),
      if (expanded)
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
            child: Text('People · most photos first'),
          ),
        ),
      if (people.isNotEmpty)
        if (expanded)
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverGrid.builder(
              gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 220,
                mainAxisExtent: height,
                crossAxisSpacing: 8,
                mainAxisSpacing: 12,
              ),
              itemCount: people.length,
              itemBuilder: (_, index) => bubble(index),
            ),
          )
        else
          SliverToBoxAdapter(
            child: SizedBox(
              height: height,
              child: ListView.separated(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                scrollDirection: Axis.horizontal,
                itemCount: people.length.clamp(0, 8),
                itemBuilder: (_, index) =>
                    SizedBox(width: 88, child: bubble(index)),
                separatorBuilder: (_, _) => const SizedBox(width: 8),
              ),
            ),
          )
      else if (c.peopleError == null)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            child: Text(
              query.isNotEmpty
                  ? 'No matching people.'
                  : c.loadingPeople
                  ? 'Loading people...'
                  : c.peopleAvailable == false
                  ? 'People is not available from your connected service.'
                  : 'People appear here when your service groups your photos.',
            ),
          ),
        ),
      if (c.peopleError case final error?)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: MessageCard(
              message: error,
              isError: true,
              onRetry: () => c.loadPeople(refresh: true),
            ),
          ),
        ),
    ];
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
                  onTap: () => actions.openCollection(tab),
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

  Widget _albumArtwork(AlbumCard album) => album.cover == null
      ? ColoredBox(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: const Center(
            child: Icon(Icons.photo_album_outlined, size: 38),
          ),
        )
      : ExcludeSemantics(
          child: MediaTile(file: album.cover!, controller: c),
        );

  Widget _albumPreview(List<AlbumCard> albums) => SliverToBoxAdapter(
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

  List<Widget> home() {
    if (expanded && showPeople) {
      return _peopleSlivers(expanded: true);
    }
    final root = c.photoRoot;
    final smartAlbums = c.smartAlbums;
    final albums = filterSmartAlbums(smartAlbums, query: query, sort: sort);
    final native = c.nativeAlbums
        .where(
          (a) =>
              query.isEmpty ||
              a.name.toLowerCase().contains(query.toLowerCase()),
        )
        .toList();
    final sharedCards = _sharedCards();
    final smartCards = albums
        .map(
          (a) => (
            name: listEquals(a.path, root) ? 'Photos at root' : a.name,
            subtitle: a.path.length <= root.length + 1
                ? ''
                : a.path
                      .skip(root.length)
                      .take(a.path.length - root.length - 1)
                      .join(' / '),
            count: '',
            cover: a.files.first,
            open: () => actions.openSmart(a.path),
          ),
        )
        .toList();
    final nativeCards = native
        .map(
          (a) => (
            name: a.name,
            subtitle: a.shared ? 'Shared album' : 'Cloud album',
            count: '${a.count} items',
            cover: a.cover,
            open: () => actions.openNative(a),
          ),
        )
        .toList();
    if (!expanded) {
      return [
        _albumSectionHeading('Pinned'),
        _pinnedCollections(),
        _albumSectionHeading(
          'Smart albums',
          expand: () => actions.expandAlbums(false),
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
                query.isNotEmpty
                    ? 'No matching Smart albums.'
                    : c.discoveringAlbums
                    ? 'Discovering your photo folders...'
                    : 'No photo albums yet. Choose a photo source in View options.',
              ),
            ),
          ),
        ..._peopleSlivers(),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Card(
              child: ListTile(
                leading: const Icon(Icons.map_outlined),
                title: const Text('Map'),
                subtitle: const Text('All photos with a saved location'),
                trailing: const Icon(Icons.chevron_right),
                onTap: actions.openMap,
              ),
            ),
          ),
        ),
        _albumSectionHeading(
          'Shared with you',
          expand: () => actions.openCollection(5),
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
          'Cloud albums',
          expand: () => actions.expandAlbums(true),
        ),
        if (nativeCards.isNotEmpty)
          _albumPreview(nativeCards)
        else if (c.nativeAlbumError == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Text('Albums from your photo service appear here.'),
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
                '${showNative ? native.length : albums.length} albums',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              if (c.discoveringAlbums && !showNative)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
      if (showNative) ...[
        if (native.isEmpty && c.nativeAlbumError == null)
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Text(
                'No cloud albums here yet. Albums from your photo service appear here with their original membership.',
              ),
            ),
          ),
        _albumCards(nativeCards),
      ],
      if (showNative && c.nativeAlbumError != null)
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
      if (!showNative) ...[
        if (albums.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                query.isNotEmpty
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

  Widget _albumCards(List<AlbumCard> albums) => SliverPadding(
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

  List<AlbumCard> _sharedCards() => c.sharedAlbums
      .where(
        (a) =>
            query.isEmpty || a.name.toLowerCase().contains(query.toLowerCase()),
      )
      .map(
        (a) => (
          name: a.name,
          subtitle: 'Shared with you',
          count: '',
          cover: a.files.first,
          open: () => actions.openShared(a.path),
        ),
      )
      .toList();

  List<Widget> shared() {
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
}
