import 'package:flutter/material.dart';

import '../../app/shell/library_scope.dart';
import '../files/file_actions.dart';
import 'album_context.dart';
import 'subfolder_paths.dart';

/// The header of an opened Smart album or shared folder: its item count, folder
/// actions and the sub-folders it can be narrowed to.
class AlbumHeader extends StatelessWidget {
  const AlbumHeader({super.key, required this.scope});

  final LibraryScope scope;

  @override
  Widget build(BuildContext context) {
    final c = scope.controller;
    return AlbumContext(
      itemCount: c.items.where((f) => f.isMedia).length,
      includesSubfolders: c.albumIncludesSubfolders,
      subfolders: subfolderPaths(c.items, c.directory),
      selected: scope.view.subfolder,
      canManageFolder: c.directory.isNotEmpty,
      onSelect: scope.selectSubfolder,
      onOpenInDrive: () {
        scope.reset();
        c.openFolder(c.currentFolder);
      },
      onFolderActions: () => fileActions(context, c, c.currentFolder),
    );
  }
}
