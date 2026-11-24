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

  /// Bytes of files still on their way that have already reached the server, so
  /// a large video moves the bar while it uploads.
  int sending = 0;

  /// Files in each step right now: being copied off the phone, being checked
  /// (checksummed), and being uploaded. A file is in one at a time.
  int copying = 0;
  int checking = 0;
  int uploading = 0;

  /// The step the latest file entered, with its name in [current].
  String step = 'Uploading';

  /// A file enters a step.
  void enter(String stepName, String name) {
    step = stepName;
    current = name;
    _count(stepName, 1);
  }

  /// A file leaves a step, finished or not.
  void leave(String stepName) => _count(stepName, -1);

  void _count(String stepName, int by) {
    switch (stepName) {
      case 'Copying':
        copying += by;
      case 'Checking':
        checking += by;
      default:
        uploading += by;
    }
  }

  /// Files that needed nothing because they were already backed up.
  int alreadyBackedUp = 0;

  /// Files that turned out to be on the server already, found while uploading.
  int recognised = 0;

  /// Files moved on the server because they were moved on the device.
  int moved = 0;

  /// Files that could not be backed up this run.
  int failed = 0;

  /// Files skipped because they have failed in several runs. They wait for the
  /// user to retry, or for the file to change.
  int blocked = 0;

  /// Uploads renamed because their destination already existed.
  int conflicts = 0;

  /// The file being uploaded now.
  String? current;

  /// Progress at recent moments, to measure speed over the last minute rather
  /// than from one file: a single large video would otherwise swing the figure
  /// wildly. Each is (time, work done, bytes sent over the network).
  final List<(DateTime, int, int)> _samples = [];
  static const _window = Duration(seconds: 60);
  int _bytesSent = 0;
  double? _bytesPerSecond;
  double? _sendRate;

  /// How fast bytes are going to the server, or null until there is enough to
  /// say. Files found already on the server do not count.
  double? get uploadSpeed => _sendRate;

  /// Files finished this run, whichever way.
  int get settled => transferred + recognised + moved + failed;

  /// Files still to do, never negative.
  int get remaining => toUpload > settled ? toUpload - settled : 0;

  /// Files that still need attention: this run's, and those waiting for a retry.
  int get problems => failed + blocked;

  /// How far through the files to upload the run is, from 0 to 1, or null while
  /// that is not known yet.
  double? get fraction {
    if (toUpload <= 0) return null;
    final byFiles = settled / toUpload;
    if (bytesTotal > 0 && bytesDone + sending > 0) {
      // Large files move the bar smoothly; many small ones keep it honest.
      return (((bytesDone + sending) / bytesTotal + byFiles) / 2).clamp(
        0.0,
        1.0,
      );
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
    _samples
      ..clear()
      ..add((now, bytesDone, _bytesSent));
    _bytesPerSecond = null;
    _sendRate = null;
  }

  /// Notes the progress at [now] and works out the speed over the last minute.
  void _measure(DateTime now) {
    _samples.add((now, bytesDone, _bytesSent));
    while (_samples.length > 2 && now.difference(_samples[1].$1) >= _window) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final seconds = now.difference(first.$1).inMilliseconds / 1000;
    if (seconds < 2) return;
    _bytesPerSecond = (bytesDone - first.$2) / seconds;
    _sendRate = (_bytesSent - first.$3) / seconds;
  }

  /// Records that a file of [bytes] was found on the server already.
  void wasOnServer(int bytes, [DateTime? now]) {
    recognised++;
    bytesDone += bytes;
    if (now != null) _measure(now);
  }

  /// Records that a file of [bytes] was moved on the server.
  void wasMoved(int bytes, [DateTime? now]) {
    moved++;
    bytesDone += bytes;
    if (now != null) _measure(now);
  }

  /// Records that a file of [bytes] was uploaded, and updates the speed.
  void uploaded(int bytes, DateTime now) {
    transferred++;
    bytesDone += bytes;
    _bytesSent += bytes;
    _measure(now);
  }

  void reset() {
    phase = '';
    found = toUpload = bytesTotal = transferred = bytesDone = sending = 0;
    step = 'Uploading';
    copying = checking = uploading = 0;
    alreadyBackedUp = recognised = moved = failed = blocked = conflicts = 0;
    current = null;
    _samples.clear();
    _bytesSent = 0;
    _bytesPerSecond = null;
    _sendRate = null;
  }

  Map<String, Object?> toJson() => {
    'found': found,
    'toUpload': toUpload,
    'bytesTotal': bytesTotal,
    'transferred': transferred,
    'bytesDone': bytesDone,
    'copying': copying,
    'checking': checking,
    'uploading': uploading,
    'alreadyBackedUp': alreadyBackedUp,
    'recognised': recognised,
    'moved': moved,
    'failed': failed,
    'blocked': blocked,
    'conflicts': conflicts,
  };
}
