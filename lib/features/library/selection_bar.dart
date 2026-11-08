import 'package:flutter/material.dart';

/// Bulk actions for the selected files: favorite, move, copy, delete, done.
class SelectionBar extends StatelessWidget {
  const SelectionBar({
    super.key,
    required this.busy,
    required this.onAction,
    required this.onDone,
  });

  final bool busy;

  /// Receives `favorite`, `move`, `copy` or `delete`.
  final ValueChanged<String> onAction;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => SafeArea(
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
                onPressed: busy ? null : () => onAction(action),
                icon: Icon(icon),
              ),
            IconButton(
              tooltip: 'Done',
              onPressed: busy ? null : onDone,
              icon: const Icon(Icons.check),
            ),
          ],
        ),
      ),
    ),
  );
}
