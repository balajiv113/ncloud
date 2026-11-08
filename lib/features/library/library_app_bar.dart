import 'package:flutter/material.dart';

/// The floating header: back or cancel, the title or search field, and the
/// search, view-options and settings actions.
class LibraryAppBar extends StatelessWidget {
  const LibraryAppBar({
    super.key,
    required this.title,
    required this.showBack,
    required this.selecting,
    required this.busy,
    required this.searching,
    required this.searchController,
    required this.initial,
    required this.showSettings,
    required this.onBack,
    required this.onQueryChanged,
    required this.onToggleSearch,
    required this.onViewOptions,
    required this.onSettings,
  });

  /// Text shown when not searching: the selection count, a nested view's
  /// name, or the app name.
  final String title;
  final bool showBack;
  final bool selecting;
  final bool busy;
  final bool searching;
  final TextEditingController searchController;

  /// Letter shown on the settings avatar.
  final String initial;
  final bool showSettings;
  final VoidCallback onBack;
  final ValueChanged<String> onQueryChanged;
  final VoidCallback onToggleSearch;
  final VoidCallback onViewOptions;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SliverAppBar(
      floating: true,
      snap: true,
      automaticallyImplyLeading: false,
      leading: showBack
          ? IconButton(
              tooltip: selecting ? 'Cancel selection' : 'Back',
              onPressed: busy ? null : onBack,
              icon: Icon(selecting ? Icons.close : Icons.arrow_back),
            )
          : null,
      titleSpacing: 16,
      title: searching
          ? TextField(
              controller: searchController,
              autofocus: true,
              onChanged: onQueryChanged,
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
              title,
              key: const ValueKey('library-title'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontWeight: FontWeight.w700,
                letterSpacing: -.7,
              ),
            ),
      actions: [
        if (!selecting) ...[
          IconButton(
            tooltip: 'Search loaded items',
            icon: Icon(searching ? Icons.close : Icons.search),
            onPressed: onToggleSearch,
          ),
          IconButton(
            tooltip: 'View options',
            onPressed: onViewOptions,
            icon: const Icon(Icons.tune_rounded),
          ),
          if (showSettings)
            IconButton(
              tooltip: 'Settings',
              onPressed: onSettings,
              icon: CircleAvatar(
                radius: 15,
                backgroundColor: colors.primaryContainer,
                child: Text(
                  initial,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.4,
                    fontWeight: FontWeight.w700,
                    color: colors.primary,
                  ),
                ),
              ),
            ),
        ],
        const SizedBox(width: 4),
      ],
    );
  }
}
