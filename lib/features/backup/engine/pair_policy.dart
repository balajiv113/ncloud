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
  if (folder.kind == DeviceSourceKind.library && ios) {
    throw const FormatException(
      'Backing up the whole photo library is available on Android first. '
      'Choose a Photos album.',
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

/// The folders of the phone's library that another backup already covers, so
/// the whole-library backup leaves them alone and no photo is uploaded twice.
///
/// Only a device folder on the phone's main storage can be matched, since the
/// library names a photo's folder the same way the folder picker does. Returns
/// the folder paths, such as `['DCIM', 'Camera']`; empty for any other backup.
List<List<String>> coveredFolders(FolderPair pair, Iterable<FolderPair> all) {
  if (pair.folder.kind != DeviceSourceKind.library) return const [];
  return [
    for (final other in all)
      if (other.id != pair.id && other.folder.kind == DeviceSourceKind.folder)
        ?_primaryFolder(other.folder.token),
  ];
}

/// The path of a folder-picker grant on main storage, or null. A grant looks
/// like `content://…/tree/primary%3ADCIM%2FCamera`.
List<String>? _primaryFolder(String token) {
  final marker = token.indexOf('/tree/');
  if (marker < 0) return null;
  final id = Uri.decodeComponent(token.substring(marker + 6));
  if (!id.startsWith('primary:')) return null;
  final path = [
    for (final part in id.substring('primary:'.length).split('/'))
      if (part.isNotEmpty) part,
  ];
  return path.isEmpty ? null : path;
}
