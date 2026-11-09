import '../state/backup_controller.dart';

/// 12431 as "12,431".
String formatCount(int value) {
  final digits = value.abs().toString();
  final out = StringBuffer(value < 0 ? '-' : '');
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}

/// A time left as a person would say it: "about 2 h left".
String formatRemaining(Duration left) {
  if (left < const Duration(minutes: 1)) return 'less than a minute left';
  if (left < const Duration(minutes: 90)) {
    return 'about ${left.inMinutes} min left';
  }
  if (left < const Duration(hours: 36)) {
    return 'about ${(left.inMinutes / 60).round()} h left';
  }
  return 'about ${(left.inHours / 24).round()} days left';
}

/// How big a file or a run is: "3.2 MB".
String formatSize(int bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var value = bytes.toDouble();
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return unit == 0
      ? '$bytes B'
      : '${value.toStringAsFixed(value < 10 ? 1 : 0)} ${units[unit]}';
}

/// The numbers a card shows for one backup, from a run in this app or from what
/// a background run saved, so both look the same.
class BackupNumbers {
  const BackupNumbers({
    this.found = 0,
    this.toUpload = 0,
    this.transferred = 0,
    this.recognised = 0,
    this.moved = 0,
    this.failed = 0,
    this.blocked = 0,
    this.bytesDone = 0,
    this.bytesTotal = 0,
    this.current,
    this.fraction,
    this.remaining,
  });

  final int found;
  final int toUpload;
  final int transferred;
  final int recognised;
  final int moved;
  final int failed;
  final int blocked;
  final int bytesDone;
  final int bytesTotal;

  /// The file being uploaded now.
  final String? current;
  final double? fraction;
  final Duration? remaining;

  factory BackupNumbers.fromProgress(SyncProgress p) => BackupNumbers(
    found: p.found,
    toUpload: p.toUpload,
    transferred: p.transferred,
    recognised: p.recognised,
    moved: p.moved,
    failed: p.failed,
    blocked: p.blocked,
    bytesDone: p.bytesDone,
    bytesTotal: p.bytesTotal,
    current: p.current,
    fraction: p.fraction,
    remaining: p.estimatedRemaining,
  );

  factory BackupNumbers.fromState(Map<String, dynamic>? state) {
    int number(String key) => (state?[key] as num?)?.toInt() ?? 0;
    final toUpload = number('toUpload');
    final settled =
        number('transferred') + number('recognised') + number('failed');
    return BackupNumbers(
      found: number('found'),
      toUpload: toUpload,
      transferred: number('transferred'),
      recognised: number('recognised'),
      moved: number('moved'),
      failed: number('failed'),
      blocked: number('blocked'),
      bytesDone: number('bytesDone'),
      bytesTotal: number('bytesTotal'),
      fraction: toUpload > 0 ? (settled / toUpload).clamp(0.0, 1.0) : null,
    );
  }

  /// Files that still need attention.
  int get problems => failed + blocked;

  int get settled => transferred + recognised + moved + failed;

  /// Files on the server after the last run, as far as the run could tell.
  int get backedUp => found > problems ? found - problems : 0;

  /// "3,204 of 12,460", or null before the amount of work is known.
  String? get progressLine => toUpload > 0
      ? '${formatCount(settled)} of ${formatCount(toUpload)}'
      : null;

  /// "26%", or null while unknown.
  String? get percent =>
      fraction == null ? null : '${(fraction! * 100).floor()}%';

  /// "12,431 of 12,460 backed up", or null when nothing was found.
  String? get summaryLine => found == 0
      ? null
      : problems == 0
      ? '${formatCount(found)} backed up$_movedNote'
      : '${formatCount(backedUp)} of ${formatCount(found)} backed up$_movedNote';

  /// " · 12 moved on the server" when files were moved to match the device.
  String get _movedNote =>
      moved == 0 ? '' : ' · ${formatCount(moved)} moved on your server';

  /// "29 could not be backed up", or null when everything went well.
  String? get problemLine => problems == 0
      ? null
      : '${formatCount(problems)} ${problems == 1 ? 'file' : 'files'} could not '
            'be backed up';
}

/// What the list shows for a pair: queued, backing up with its count so far,
/// or how its last run ended.
String pairStatus(BackupController sync, FolderPair pair) {
  if (sync.queuedIds.contains(pair.id)) return 'Queued';
  if (sync.activeId == pair.id) {
    final numbers = BackupNumbers.fromProgress(sync.progress);
    return numbers.progressLine == null
        ? 'Backing up'
        : 'Backing up · ${numbers.progressLine}';
  }
  return switch (sync.results[pair.id]?['status']) {
    'running' => 'Backing up',
    'success' => 'Completed',
    'partial' => 'Completed with problems',
    'paused' || 'interrupted' => 'Paused',
    'error' => 'Failed',
    _ => 'Ready',
  };
}
