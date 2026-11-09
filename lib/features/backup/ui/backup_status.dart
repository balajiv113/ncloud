import '../state/backup_controller.dart';

/// What the list shows for a pair: queued, backing up with its count so far,
/// or how its last run ended.
String pairStatus(BackupController sync, FolderPair pair) {
  if (sync.queuedIds.contains(pair.id)) return 'Queued';
  if (sync.activeId == pair.id) {
    return 'Backing up · ${sync.transferred} files confirmed';
  }
  return switch (sync.results[pair.id]?['status']) {
    'running' => 'Backing up',
    'success' => 'Completed',
    'paused' || 'interrupted' => 'Paused',
    'error' => 'Failed',
    _ => 'Ready',
  };
}
