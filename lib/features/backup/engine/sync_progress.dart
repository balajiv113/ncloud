/// What a running backup is doing, for the screen and the notification.
///
/// The counts are everything the user needs to see: how much there is, how much
/// is done, how much was already backed up, and how much went wrong.
class SyncProgress {
  String phase = '';

  /// Files found on the device that the pair's rules allow.
  int found = 0;

  /// Files this run has to upload, and their size.
  int toUpload = 0;
  int bytesTotal = 0;

  /// Files uploaded and confirmed during this run, and their size.
  int transferred = 0;
  int bytesDone = 0;

  /// Files that needed nothing because they were already backed up.
  int alreadyBackedUp = 0;

  /// Files that turned out to be on the server already, found while uploading.
  int recognised = 0;

  /// Files that could not be backed up this run.
  int failed = 0;

  /// Files skipped because they have failed in several runs. They wait for the
  /// user to retry, or for the file to change.
  int blocked = 0;

  /// Uploads renamed because their destination already existed.
  int conflicts = 0;

  /// The file being uploaded now.
  String? current;

  DateTime? _lastSample;
  int _lastBytes = 0;
  double? _bytesPerSecond;

  /// Files finished this run, whichever way.
  int get settled => transferred + recognised + failed;

  /// Files still to do, never negative.
  int get remaining => toUpload > settled ? toUpload - settled : 0;

  /// Files that still need attention: this run's, and those waiting for a retry.
  int get problems => failed + blocked;

  /// How far through the files to upload the run is, from 0 to 1, or null while
  /// that is not known yet.
  double? get fraction {
    if (toUpload <= 0) return null;
    final byFiles = settled / toUpload;
    if (bytesTotal > 0 && bytesDone > 0) {
      // Large files move the bar smoothly; many small ones keep it honest.
      return ((bytesDone / bytesTotal + byFiles) / 2).clamp(0.0, 1.0);
    }
    return byFiles.clamp(0.0, 1.0);
  }

  /// A rough time left, from the recent upload speed, or null until there is
  /// enough to go on.
  Duration? get estimatedRemaining {
    final speed = _bytesPerSecond;
    if (speed == null || speed < 1 || bytesTotal <= bytesDone) return null;
    return Duration(seconds: ((bytesTotal - bytesDone) / speed).round());
  }

  /// Starts timing a run's uploads.
  void begin(DateTime now) {
    _lastSample = now;
    _lastBytes = bytesDone;
    _bytesPerSecond = null;
  }

  /// Records that a file of [bytes] was found on the server already.
  void wasOnServer(int bytes) {
    recognised++;
    bytesDone += bytes;
  }

  /// Records that a file of [bytes] was uploaded, and updates the speed.
  void uploaded(int bytes, DateTime now) {
    transferred++;
    bytesDone += bytes;
    final last = _lastSample ?? now;
    final seconds = now.difference(last).inMilliseconds / 1000;
    if (seconds < 2) return;
    final sample = (bytesDone - _lastBytes) / seconds;
    // Weighted towards recent speed so the estimate follows the connection.
    _bytesPerSecond = _bytesPerSecond == null
        ? sample
        : _bytesPerSecond! * 0.7 + sample * 0.3;
    _lastSample = now;
    _lastBytes = bytesDone;
  }

  void reset() {
    phase = '';
    found = toUpload = bytesTotal = transferred = bytesDone = 0;
    alreadyBackedUp = recognised = failed = blocked = conflicts = 0;
    current = null;
    _lastSample = null;
    _lastBytes = 0;
    _bytesPerSecond = null;
  }

  Map<String, Object?> toJson() => {
    'found': found,
    'toUpload': toUpload,
    'bytesTotal': bytesTotal,
    'transferred': transferred,
    'bytesDone': bytesDone,
    'alreadyBackedUp': alreadyBackedUp,
    'recognised': recognised,
    'failed': failed,
    'blocked': blocked,
    'conflicts': conflicts,
  };
}
