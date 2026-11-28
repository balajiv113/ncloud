import 'package:material_ui/material_ui.dart';

import '../platform/album_folders.dart';

/// Lets the user tick the Photos albums to leave out of a whole-library backup.
/// A photo in a ticked album is not backed up, even if another album holds it.
/// Closes with the ticked albums.
class AlbumExcludeSheet extends StatefulWidget {
  const AlbumExcludeSheet({
    super.key,
    required this.available,
    required this.chosen,
    this.title = 'Leave out albums',
    this.empty = 'There are no albums to choose from.',
  });

  final List<AlbumChoice> available;
  final List<AlbumChoice> chosen;
  final String title;
  final String empty;

  @override
  State<AlbumExcludeSheet> createState() => _AlbumExcludeSheetState();
}

class _AlbumExcludeSheetState extends State<AlbumExcludeSheet> {
  late final Set<String> _ticked = {for (final a in widget.chosen) a.token};

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
              child: Text(widget.title, style: theme.textTheme.titleLarge),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'Photos and videos in these are not backed up. What was already '
                'backed up stays on your server.',
                style: theme.textTheme.bodySmall,
              ),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final album in widget.available)
                    CheckboxListTile(
                      title: Text(album.name),
                      subtitle: album.subtitle == null
                          ? null
                          : Text(album.subtitle!),
                      value: _ticked.contains(album.token),
                      onChanged: (on) => setState(
                        () => on == true
                            ? _ticked.add(album.token)
                            : _ticked.remove(album.token),
                      ),
                    ),
                  if (widget.available.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(widget.empty),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop([
                    for (final a in widget.available)
                      if (_ticked.contains(a.token)) a,
                  ]),
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
