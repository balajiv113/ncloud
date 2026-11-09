import '../platform/folder_access.dart';
import '../state/sync_journal.dart';
import '../model/backup_schedule.dart';

/// Whether [a] is [b] or a folder above it.
bool _contains(List<String> a, List<String> b) =>
    a.length <= b.length &&
    List.generate(a.length, (i) => a[i] == b[i]).every((v) => v);

/// Rejects a folder pair that cannot be backed up safely, with a message the
/// user can act on. Throws [FormatException]; returns normally when valid.
///
/// A device folder can back up to one place only, and two pairs may not write
/// into the same or nested cloud folders. [replacing] is the pair being edited,
/// which does not conflict with itself.
void validatePair({
  required DeviceFolder folder,
  required List<String> remote,
  required int uploadConcurrency,
  required BackupSchedule? schedule,
  required bool schedulerSupported,
  required bool ios,
  required Iterable<FolderPair> existing,
  FolderPair? replacing,
}) {
  checkSyncPath(remote);
  checkSyncPath([folder.name]);
  validateConcurrency(uploadConcurrency);
  if (folder.kind == DeviceSourceKind.photoAlbum && !ios) {
    throw const FormatException(
      'Apple Photos albums support upload-only backup on iOS.',
    );
  }
  if (schedule != null && !schedulerSupported) {
    throw const FormatException(
      'Scheduled backups require a supported upload-only source.',
    );
  }
  if (schedule != null && ios && folder.kind != DeviceSourceKind.photoAlbum) {
    throw const FormatException(
      'iOS background backups currently support Apple Photos albums only.',
    );
  }
  final cloudRoot = [...remote, folder.name];
  final clashes = existing.any(
    (pair) =>
        pair.id != replacing?.id &&
        (pair.folder.identity == folder.identity ||
            _contains(pair.cloudRoot, cloudRoot) ||
            _contains(cloudRoot, pair.cloudRoot)),
  );
  if (clashes) {
    throw const FormatException(
      'Choose a different device folder and a non-overlapping cloud folder.',
    );
  }
}

/// Uploads run one to three files at a time.
void validateConcurrency(int concurrency) {
  if (concurrency < 1 || concurrency > 3) {
    throw const FormatException('Use 1 to 3 uploads.');
  }
}
