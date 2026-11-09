import 'package:flutter/material.dart';

import 'library_view.dart';

/// The choices the view-options sheet edits.
typedef ViewOptions = ({MediaFilter filter, LibrarySort sort, int density});

/// Shows the view options for the current destination. [onChanged] receives
/// every change as it is made; the sheet stays open.
Future<void> showViewOptions(
  BuildContext context, {
  required ViewOptions options,
  required ValueChanged<ViewOptions> onChanged,
  required bool drive,
  required bool albumHome,
  required bool showPeople,
  required bool captureDates,
  required List<String> photoRoot,
  required VoidCallback onChooseSource,
}) async {
  var current = options;
  await showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (sheetContext) => StatefulBuilder(
      builder: (context, update) {
        void choose(ViewOptions next) {
          current = next;
          update(() {});
          onChanged(next);
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'View options',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 14),
                if (!drive && !albumHome) ...[
                  const Text('Show'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final value in MediaFilter.values)
                        ChoiceChip(
                          label: Text(switch (value) {
                            MediaFilter.all => 'All',
                            MediaFilter.photos => 'Photos',
                            MediaFilter.videos => 'Videos',
                            MediaFilter.favorites => 'Favorites',
                          }),
                          selected: current.filter == value,
                          onSelected: (_) {
                            choose((
                              filter: value,
                              sort: current.sort,
                              density: current.density,
                            ));
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  const Text('Grid density'),
                  Wrap(
                    spacing: 8,
                    children: [
                      for (var value = 2; value <= 6; value++)
                        ChoiceChip(
                          label: Text('$value'),
                          selected: value == current.density,
                          onSelected: (_) {
                            choose((
                              filter: current.filter,
                              sort: current.sort,
                              density: value,
                            ));
                          },
                        ),
                    ],
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Sort'),
                if (albumHome && showPeople)
                  const ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Most photos first'),
                    trailing: Icon(Icons.check),
                  ),
                if (!(albumHome && showPeople))
                  for (final (value, label) in [
                    (LibrarySort.newest, 'Newest first'),
                    (LibrarySort.oldest, 'Oldest first'),
                    (LibrarySort.name, 'Name A-Z'),
                    if (!albumHome) (LibrarySort.size, 'Largest first'),
                  ])
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(label),
                      trailing: current.sort == value
                          ? const Icon(Icons.check)
                          : null,
                      onTap: () {
                        choose((
                          filter: current.filter,
                          sort: value,
                          density: current.density,
                        ));
                      },
                    ),
                if (albumHome)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.folder_open_outlined),
                    title: const Text('Choose photo source'),
                    subtitle: Text(
                      'My drive${photoRoot.isEmpty ? '' : ' / ${photoRoot.join(' / ')}'}',
                    ),
                    onTap: () {
                      Navigator.pop(sheetContext);
                      onChooseSource();
                    },
                  ),
                if (!albumHome)
                  Text(
                    captureDates
                        ? 'Capture dates. Photos load as you scroll.'
                        : 'Modification dates. Photos load as you scroll.',
                    style: const TextStyle(fontSize: 11),
                  ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
