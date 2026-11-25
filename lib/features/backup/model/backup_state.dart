/// Where a photo on the phone stands with the backup.
///
/// The values run from best to worst, so when several backups cover the same
/// photo, the one that is furthest along is the one that counts.
enum BackupState {
  /// It is on the server.
  backedUp,

  /// It will be uploaded by the next run.
  waiting,

  /// It was tried and could not be uploaded.
  failed,

  /// No backup covers it.
  leftOut,
}
