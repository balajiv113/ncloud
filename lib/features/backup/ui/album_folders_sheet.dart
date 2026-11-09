import 'package:flutter/material.dart';

import '../platform/album_folders.dart';

/// Lets the user choose which Photos albums get a folder of their own, and in
/// what order. A photo that is in several albums goes to the first of them.
/// Closes with the chosen albums, in order.
class AlbumFoldersSheet extends StatefulWidget {
  const AlbumFoldersSheet({
    super.key,
    required this.available,
    required this.chosen,
  });

  final List<AlbumChoice> available;
  final List<AlbumChoice> chosen;

  @override
  State<AlbumFoldersSheet> createState() => _AlbumFoldersSheetState();
}

class _AlbumFoldersSheetState extends State<AlbumFoldersSheet> {
  late final List<AlbumChoice> _chosen = List.of(widget.chosen);

  List<AlbumChoice> get _rest => [
    for (final album in widget.available)
      if (!_chosen.any((c) => c.token == album.token)) album,
  ];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
              child: Text(
                'Albums in their own folders',
                style: theme.textTheme.titleLarge,
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Each photo is stored once. A photo in several albums goes to '
                'the first one in this list; photos in none of them stay in '
                'Camera Roll. Moving a photo into an album moves it on your '
                'server too.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (_chosen.isNotEmpty)
                    ReorderableListView(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      onReorder: (from, to) => setState(() {
                        final moved = _chosen.removeAt(from);
                        _chosen.insert(to > from ? to - 1 : to, moved);
                      }),
                      children: [
                        for (final (index, album) in _chosen.indexed)
                          ListTile(
                            key: ValueKey(album.token),
                            leading: CircleAvatar(
                              radius: 12,
                              child: Text('${index + 1}'),
                            ),
                            title: Text(album.name),
                            trailing: IconButton(
                              tooltip: 'Remove ${album.name}',
                              icon: const Icon(Icons.remove_circle_outline),
                              onPressed: () =>
                                  setState(() => _chosen.remove(album)),
                            ),
                          ),
                      ],
                    ),
                  if (_rest.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                      child: Text(
                        'Add an album',
                        style: theme.textTheme.titleSmall,
                      ),
                    ),
                  for (final album in _rest)
                    ListTile(
                      title: Text(album.name),
                      trailing: const Icon(Icons.add_circle_outline),
                      onTap: () => setState(() => _chosen.add(album)),
                    ),
                  if (widget.available.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('There are no albums to choose from.'),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(List.of(_chosen)),
                  child: const Text('Done'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
