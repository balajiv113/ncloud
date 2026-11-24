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

  /// The files being worked on right now, each with its own step and bytes.
  /// The counts, the bar and the per-file rows all come from this list, so they
  /// cannot disagree.
  final List<ActiveFile> active = [];

  /// A file starts being worked on.
  ActiveFile start(String name, int size) {
    final file = ActiveFile(name, size);
    active.add(file);
    return file;
  }

  /// A file is finished with, whether it worked or not.
  void finish(ActiveFile file) => active.remove(file);

  /// Files in each step right now: waiting for a turn, being copied off the phone, being checked
  /// (checksummed), and being uploaded. A file is in one at a time.
  int get waiting => active.where((f) => f.step == ActiveFile.wait).length;
  int get copying => active.where((f) => f.step == ActiveFile.copy).length;
  int get checking => active.where((f) => f.step == ActiveFile.check).length;
  int get uploading => active.where((f) => f.step == ActiveFile.upload).length;

  /// Bytes of files still on their way that have already reached the server.
  int get sending => active.fold(0, (sum, f) => sum + f.sent);

  /// Work done on the files in hand, as a share of whole files.
  double get _partial => active.fold(0.0, (sum, f) => sum + f.fraction);

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
  /// that is not known yet. Files in hand count for the part of their work that
  /// is done: a fifth for the copy off the phone, the rest for the upload.
  double? get fraction {
    if (toUpload <= 0) return null;
    if (bytesTotal > 0) {
      final inHand = active.fold(0.0, (sum, f) => sum + f.size * f.fraction);
      return ((bytesDone + inHand) / bytesTotal).clamp(0.0, 1.0);
    }
    return ((settled + _partial) / toUpload).clamp(0.0, 1.0);
  }

  /// A rough time left, from the recent upload speed, or null until there is
  /// enough to go on.
  Duration? get estimatedRemaining {
    final speed = _bytesPerSecond;
    final left = bytesTotal - bytesDone - sending;
    if (speed == null || speed < 1 || left <= 0) return null;
    return Duration(seconds: (left / speed).round());
  }

  /// Starts timing a run's uploads.
  void begin(DateTime now) {
    _samples
      ..clear()
      ..add((now, bytesDone + sending, _bytesSent + sending));
    _bytesPerSecond = null;
    _sendRate = null;
  }

  /// Notes the progress at [now] and works out the speed over the last minute.
  void _measure(DateTime now) {
    final done = bytesDone + sending;
    final sent = _bytesSent + sending;
    _samples.add((now, done, sent));
    while (_samples.length > 2 && now.difference(_samples[1].$1) >= _window) {
      _samples.removeAt(0);
    }
    final first = _samples.first;
    final seconds = now.difference(first.$1).inMilliseconds / 1000;
    if (seconds < 2) return;
    _bytesPerSecond = (done - first.$2) / seconds;
    _sendRate = (sent - first.$3) / seconds;
  }

  /// Notes that bytes are moving, at most once a second, so the speed and the
  /// time left follow a large file while it uploads.
  void moving(DateTime now) {
    if (_samples.isNotEmpty &&
        now.difference(_samples.last.$1) < const Duration(seconds: 1)) {
      return;
    }
    _measure(now);
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
    found = toUpload = bytesTotal = transferred = bytesDone = 0;
    active.clear();
    alreadyBackedUp = recognised = moved = failed = blocked = conflicts = 0;
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
    'fraction': fraction,
    'waiting': waiting,
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

/// One file being worked on: copied off the phone, checked, then uploaded.
class ActiveFile {
  ActiveFile(this.name, this.size);

  static const wait = 'Waiting';
  static const copy = 'Copying';
  static const check = 'Checking';
  static const upload = 'Uploading';

  final String name;

  /// Its size, or a negative number when the phone does not say.
  final int size;

  /// Waiting for its turn until the copy starts.
  String step = wait;

  /// Bytes copied off the phone so far, and bytes sent to the server so far.
  int copied = 0;
  int sent = 0;

  /// How much of this file's work is done, from 0 to 1. The copy is a fifth,
  /// because the fingerprint is taken in the same pass and the upload is what
  /// takes the time.
  double get fraction {
    const copyShare = 0.2;
    final copyPart = step == wait
        ? 0.0
        : step == copy
        ? (size > 0 ? (copied / size).clamp(0.0, 1.0) : 0.0)
        : 1.0;
    final uploadPart = step == upload && size > 0
        ? (sent / size).clamp(0.0, 1.0)
        : 0.0;
    return copyShare * copyPart + (1 - copyShare) * uploadPart;
  }
}
