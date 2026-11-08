import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../core/ui/messages.dart';
import '../../discovery_models.dart';
import '../../shared/ui/media_tile.dart';
import '../photos/people_bubble.dart';
import 'domain/album_entries.dart';
import 'domain/library_view.dart';

/// How the Albums destination asks the screen to navigate; the screen also
/// resets its own view state and scroll position.
class AlbumHomeActions {
  const AlbumHomeActions({
    required this.openAlbum,
    required this.openPerson,
    required this.expandAlbums,
    required this.expandPeople,
    required this.openMap,
    required this.openCollection,
  });

  final void Function(AlbumEntry album) openAlbum;
  final void Function(RecognizedPerson person) openPerson;
  final VoidCallback expandAlbums;
  final VoidCallback expandPeople;
  final VoidCallback openMap;
  final void Function(int tab) openCollection;
}

/// The Albums destination: pinned shortcuts, People and every album in one
/// list, or one of those two sections expanded.
class AlbumHomeSlivers extends StatelessWidget {
  const AlbumHomeSlivers({
    super.key,
    required this.controller,
    required this.query,
    required this.sort,
    required this.expanded,
    required this.showPeople,
    required this.actions,
  });

  final AppController controller;
  final String query;
  final LibrarySort sort;
  final bool expanded;
  final bool showPeople;
  final AlbumHomeActions actions;

  @override
  Widget build(BuildContext context) => SliverMainAxisGroup(
    slivers: _AlbumSections(
      context: context,
      c: controller,
      query: query,
      expanded: expanded,
      actions: actions,
      albums: albumEntries(
        smart: controller.smartAlbums,
        shared: controller.sharedAlbums,
        server: controller.nativeAlbums,
        root: controller.photoRoot,
        query: query,
        sort: sort,
      ),
    ).home(showPeople: showPeople),
  );
}

class _AlbumSections {
  const _AlbumSections({
    required this.context,
    required this.c,
    required this.query,
    required this.expanded,
    required this.actions,
    required this.albums,
  });

  final BuildContext context;
  final AppController c;
  final String query;
  final bool expanded;
  final AlbumHomeActions actions;
  final List<AlbumEntry> albums;

  static IconData _icon(AlbumKind kind) => switch (kind) {
    AlbumKind.smart => Icons.auto_awesome_outlined,
    AlbumKind.shared => Icons.folder_shared_outlined,
    AlbumKind.server => Icons.photo_album_outlined,
  };

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
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            for (final (index, (label, tooltip, icon, open)) in [
              (
                'Favorites',
                'Favorites',
                Icons.favorite_border,
                () => actions.openCollection(2),
              ),
              (
                'Offline',
                'Offline',
                Icons.offline_bolt_outlined,
                () => actions.openCollection(6),
              ),
              (
                'Bin',
                'Recently deleted',
                Icons.restore_from_trash_outlined,
                () => actions.openCollection(3),
              ),
              ('Map', 'Photo map', Icons.map_outlined, actions.openMap),
            ].indexed) ...[
              if (index > 0) const SizedBox(width: 8),
              Expanded(
                child: Tooltip(
                  message: tooltip,
                  child: Material(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(20),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(20),
                      onTap: open,
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
              ),
            ],
          ],
        ),
      ),
    ),
  );

  Widget _albumArtwork(AlbumEntry album) => album.cover == null
      ? ColoredBox(
          color: Theme.of(context).colorScheme.primaryContainer,
          child: Center(child: Icon(_icon(album.kind), size: 38)),
        )
      : ExcludeSemantics(
          child: MediaTile(file: album.cover!, controller: c),
        );

  /// Small icon on a cover that tells Smart and Shared albums apart; server
  /// albums are the ordinary case and carry none.
  Widget _albumBadge(AlbumEntry album) {
    if (album.kind == AlbumKind.server) return const SizedBox.shrink();
    return Positioned(
      left: 8,
      top: 8,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .55),
            shape: BoxShape.circle,
          ),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(_icon(album.kind), size: 14, color: Colors.white),
          ),
        ),
      ),
    );
  }

  Widget _albumPreview(List<AlbumEntry> albums) => SliverToBoxAdapter(
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
              label: [album.name, album.kindLabel].nonNulls.join(', '),
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
                    _albumBadge(album),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(onTap: () => actions.openAlbum(album)),
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

  Widget _albumCards(List<AlbumEntry> albums) => SliverPadding(
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
              label: [
                album.name,
                album.kindLabel,
                album.count,
              ].nonNulls.where((part) => part.isNotEmpty).join(', '),
              child: InkWell(
                borderRadius: BorderRadius.circular(14),
                onTap: () => actions.openAlbum(album),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      height: width,
                      width: width,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(14),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [_albumArtwork(album), _albumBadge(album)],
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

  Widget _errorCard(String message) => SliverToBoxAdapter(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: MessageCard(message: message, isError: true, onRetry: c.load),
    ),
  );

  String get _emptyText => query.isNotEmpty
      ? 'No matching albums.'
      : c.discoveringAlbums
      ? 'Discovering your photo folders...'
      : c.loadingSharedAlbums
      ? 'Loading albums...'
      : 'No albums yet. Choose a photo source in View options.';

  List<Widget> home({required bool showPeople}) {
    if (expanded && showPeople) return _peopleSlivers(expanded: true);
    final errors = [?c.sharedAlbumError, ?c.nativeAlbumError];
    if (!expanded) {
      return [
        _albumSectionHeading('Pinned'),
        _pinnedCollections(),
        _albumSectionHeading('Albums', expand: actions.expandAlbums),
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
        if (albums.isNotEmpty)
          _albumPreview(albums)
        else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
              child: Text(_emptyText),
            ),
          ),
        for (final error in errors) _errorCard(error),
        ..._peopleSlivers(),
      ];
    }
    return [
      SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Row(
            children: [
              Text(
                '${albums.length} albums',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(width: 8),
              if (c.discoveringAlbums)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ),
      ),
      if (albums.isEmpty)
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_emptyText),
          ),
        ),
      for (final error in errors) _errorCard(error),
      _albumCards(albums),
    ];
  }
}
