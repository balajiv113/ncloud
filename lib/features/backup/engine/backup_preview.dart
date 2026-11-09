/// How much of one phone folder is waiting to be backed up.
class FolderShare {
  const FolderShare(this.name, this.files, this.bytes);

  final String name;
  final int files;
  final int bytes;
}

/// What a backup would do if it ran now, worked out without changing anything:
/// nothing is uploaded, no folder is made on the server and no record is kept.
class BackupPreview {
  const BackupPreview({
    required this.found,
    required this.alreadyBackedUp,
    required this.toUpload,
    required this.bytes,
    required this.blocked,
    required this.folders,
    this.oldest,
    this.newest,
    this.destinationExists,
  });

  /// Files on the device that the backup's rules allow.
  final int found;

  /// Files that were backed up before and have not changed.
  final int alreadyBackedUp;

  /// Files that would be uploaded, and their total size.
  final int toUpload;
  final int bytes;

  /// Files that have failed again and again and wait for the user to retry.
  final int blocked;

  /// Where the files to upload are, largest first.
  final List<FolderShare> folders;

  /// The dates (as the device reports them) of the oldest and newest file to
  /// upload.
  final DateTime? oldest;
  final DateTime? newest;

  /// Whether the folder on the server already exists, or null when the server
  /// could not be asked.
  final bool? destinationExists;

  bool get isEmpty => toUpload == 0;
}
