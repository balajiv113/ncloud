import 'package:flutter/material.dart';

import '../../app/shell/library_scope.dart';
import '../../models.dart';
import '../../shared/ui/drive_list.dart';
import '../../shared/ui/empty_library.dart';

/// The folder being browsed in Drive: breadcrumbs above its files and folders.
class DriveView extends StatelessWidget {
  const DriveView({super.key, required this.scope, required this.files});

  final LibraryScope scope;
  final List<CloudFile> files;

  @override
  Widget build(BuildContext context) {
    final c = scope.controller;
    final view = scope.view;
    return SliverMainAxisGroup(
      slivers: [
        if (c.directory.isNotEmpty) SliverToBoxAdapter(child: _breadcrumbs()),
        DriveList(
          files: files,
          controller: c,
          selected: view.selected.keys.toSet(),
          selecting: view.selecting,
          onOpen: scope.open,
          onToggle: scope.toggle,
        ),
        if (files.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: EmptyLibrary(
              failed: c.error != null,
              hasMore: c.hasMore,
              message: scope.emptyMessage,
            ),
          ),
      ],
    );
  }

  Widget _breadcrumbs() {
    final c = scope.controller;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          TextButton(
            onPressed: () {
              scope.reset();
              c.goTo([]);
            },
            child: const Text('All files'),
          ),
          for (var index = 0; index < c.directory.length; index++) ...[
            const Icon(Icons.chevron_right, size: 14),
            TextButton(
              onPressed: () {
                final path = c.directory.take(index + 1).toList();
                scope.reset();
                c.goTo(path);
              },
              child: Text(c.directory[index]),
            ),
          ],
        ],
      ),
    );
  }
}
