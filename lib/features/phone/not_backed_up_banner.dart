import 'package:material_ui/material_ui.dart';

import '../../app/app_controller.dart';
import '../backup/model/backup_state.dart';
import '../backup/ui/folder_backup_screen.dart';

/// The top of an album that has photos only on the phone: how many are in each
/// state, and the way to the settings that decide what gets backed up.
class NotBackedUpBanner extends StatelessWidget {
  const NotBackedUpBanner({super.key, required this.controller});

  final AppController controller;

  /// "12 waiting · 3 left out", counting only the states that occur.
  static String summary(Map<BackupState, int> counts) => [
    for (final (state, word) in const [
      (BackupState.waiting, 'waiting to back up'),
      (BackupState.failed, 'could not be backed up'),
      (BackupState.leftOut, 'left out'),
    ])
      if ((counts[state] ?? 0) > 0) '${counts[state]} $word',
  ].join(' · ');

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              const Icon(Icons.cloud_off_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Not backed up'),
                    Text(
                      summary(controller.phoneView.counts),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
              TextButton(
                onPressed: () => Navigator.push<void>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => FolderBackupScreen(controller: controller),
                  ),
                ),
                child: const Text('Choose what to back up'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
