import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

/// The header of an opened album or folder view: how many items it holds, a
/// menu of folder actions and chips to narrow it to one sub-folder.
class AlbumContext extends StatelessWidget {
  const AlbumContext({
    super.key,
    required this.itemCount,
    required this.includesSubfolders,
    required this.subfolders,
    required this.selected,
    required this.canManageFolder,
    required this.onSelect,
    required this.onOpenInDrive,
    required this.onFolderActions,
  });

  final int itemCount;
  final bool includesSubfolders;
  final List<List<String>> subfolders;

  /// The sub-folder the view is narrowed to, or null for all photos.
  final List<String>? selected;

  /// Whether the folder has its own actions; the album's root does not.
  final bool canManageFolder;
  final ValueChanged<List<String>?> onSelect;
  final VoidCallback onOpenInDrive;
  final VoidCallback onFolderActions;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '$itemCount items'
                '${includesSubfolders ? ', including subfolders' : ', in this folder only'}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            PopupMenuButton<String>(
              tooltip: 'Album actions',
              onSelected: (action) =>
                  action == 'drive' ? onOpenInDrive() : onFolderActions(),
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'drive',
                  child: Text('Open in Drive'),
                ),
                if (canManageFolder)
                  const PopupMenuItem(
                    value: 'actions',
                    child: Text('Folder actions'),
                  ),
              ],
            ),
          ],
        ),
      ),
      if (subfolders.isNotEmpty)
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Row(
            children: [
              ChoiceChip(
                label: const Text('All photos'),
                selected: selected == null,
                onSelected: (_) => onSelect(null),
              ),
              for (final path in subfolders)
                Padding(
                  padding: const EdgeInsets.only(left: 7),
                  child: ChoiceChip(
                    label: Text(path.last),
                    selected: selected != null && listEquals(selected!, path),
                    onSelected: (_) => onSelect(path),
                  ),
                ),
            ],
          ),
        ),
    ],
  );
}
