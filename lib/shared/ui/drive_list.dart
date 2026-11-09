import 'package:flutter/material.dart';

import '../../app/app_controller.dart';
import '../../models.dart';
import '../../features/files/file_actions.dart';
import 'media_tile.dart';

/// The line under a file's name: its kind or size, and who it is shared with.
String driveSubtitle(CloudFile file) {
  final kind = file.isDirectory ? 'Folder' : formatBytes(file.size);
  return switch (file.sharing) {
    Sharing.none => kind,
    Sharing.byMe => '$kind · Shared by you',
    Sharing.withMe => '$kind · Shared with you',
  };
}

IconData _icon(CloudFile file) {
  if (!file.isDirectory) return Icons.description_outlined;
  return switch (file.sharing) {
    Sharing.none => Icons.folder_outlined,
    Sharing.byMe => Icons.folder_shared_outlined,
    Sharing.withMe => Icons.folder_shared,
  };
}

/// Files and folders as a list, with selection marks and a per-file menu.
class DriveList extends StatelessWidget {
  const DriveList({
    super.key,
    required this.files,
    required this.controller,
    required this.selected,
    required this.selecting,
    required this.onOpen,
    required this.onToggle,
  });

  final List<CloudFile> files;
  final AppController controller;
  final Set<String> selected;
  final bool selecting;
  final void Function(CloudFile file, List<CloudFile> visible) onOpen;
  final void Function(CloudFile file) onToggle;

  @override
  Widget build(BuildContext context) => SliverPadding(
    padding: const EdgeInsets.symmetric(horizontal: 12),
    sliver: SliverList.builder(
      itemCount: files.length,
      itemBuilder: (context, index) {
        final file = files[index];
        final colors = Theme.of(context).colorScheme;
        return ListTile(
          key: ValueKey('drive:${file.key}'),
          contentPadding: const EdgeInsets.symmetric(horizontal: 4),
          selected: selected.contains(file.key),
          selectedTileColor: colors.primaryContainer,
          onTap: () => onOpen(file, files),
          onLongPress: file.readOnly ? null : () => onToggle(file),
          leading: selecting
              ? Icon(
                  selected.contains(file.key)
                      ? Icons.check_circle
                      : Icons.radio_button_unchecked,
                )
              : SizedBox(
                  width: 40,
                  height: 40,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: file.isMedia
                        ? MediaTile(file: file, controller: controller)
                        : ColoredBox(
                            color: colors.surfaceContainerHigh,
                            child: Icon(
                              _icon(file),
                              color: file.sharing == Sharing.withMe
                                  ? colors.tertiary
                                  : colors.primary,
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
            driveSubtitle(file),
            style: const TextStyle(fontSize: 11, height: 1.4),
          ),
          trailing: selecting
              ? null
              : IconButton(
                  tooltip: 'Actions for ${file.name}',
                  onPressed: controller.busy
                      ? null
                      : () => fileActions(context, controller, file),
                  icon: const Icon(Icons.more_vert, size: 20),
                ),
        );
      },
    ),
  );
}
