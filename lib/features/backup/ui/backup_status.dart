import '../engine/sync_progress.dart';
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

/// One file in hand, as a row on the card: its name, its step and how far it
/// has got.
class FileRow {
  const FileRow(this.name, this.step, this.fraction, this.detail);

  factory FileRow.of(ActiveFile f) {
    final known = f.size > 0;
    final done = f.step == ActiveFile.copy
        ? f.copied
        : f.step == ActiveFile.upload
        ? f.sent
        : 0;
    final share = !known || f.step == ActiveFile.check
        ? null
        : (done / f.size).clamp(0.0, 1.0);
    final detail = switch (f.step) {
      ActiveFile.check => 'Checking',
      _ when known =>
        '${f.step} ${(share! * 100).floor()}% · '
            '${formatSize(done)} of ${formatSize(f.size)}',
      _ when done > 0 => '${f.step} ${formatSize(done)}',
      _ => f.step,
    };
    return FileRow(f.name, f.step, share, detail);
  }

  final String name;
  final String step;

  /// How far through this step the file is, or null when that is not known.
  final double? fraction;
  final String detail;
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
    this.files = const [],
    this.waiting = 0,
    this.copying = 0,
    this.checking = 0,
    this.uploading = 0,
    this.bytesTotal = 0,
    this.fraction,
    this.remaining,
    this.bytesPerSecond,
  });

  final int found;
  final int toUpload;
  final int transferred;
  final int recognised;
  final int moved;
  final int failed;
  final int blocked;
  final int bytesDone;
  final List<FileRow> files;
  final int waiting;
  final int copying;
  final int checking;
  final int uploading;
  final int bytesTotal;

  /// The file being uploaded now.
  final double? fraction;
  final Duration? remaining;

  /// How fast bytes are going to the server right now, if known.
  final double? bytesPerSecond;

  factory BackupNumbers.fromProgress(SyncProgress p) => BackupNumbers(
    found: p.found,
    toUpload: p.toUpload,
    transferred: p.transferred,
    recognised: p.recognised,
    moved: p.moved,
    failed: p.failed,
    blocked: p.blocked,
    bytesDone: p.bytesDone + p.sending,
    files: [
      for (final f in p.active)
        if (f.step != ActiveFile.wait) FileRow.of(f),
    ],
    waiting: p.waiting,
    copying: p.copying,
    checking: p.checking,
    uploading: p.uploading,
    bytesTotal: p.bytesTotal,
    fraction: p.fraction,
    remaining: p.estimatedRemaining,
    bytesPerSecond: p.uploadSpeed,
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
      waiting: number('waiting'),
      copying: number('copying'),
      checking: number('checking'),
      uploading: number('uploading'),
      bytesTotal: number('bytesTotal'),
      fraction:
          (state?['fraction'] as num?)?.toDouble() ??
          (toUpload > 0 ? (settled / toUpload).clamp(0.0, 1.0) : null),
    );
  }

  /// What has gone and how fast, such as "4.1 GB of 18.2 GB · 0.9 MB/s", or
  /// null before the total is known.
  String? get sizeLine {
    if (bytesTotal <= 0) return null;
    final speed = bytesPerSecond;
    return '${formatSize(bytesDone)} of ${formatSize(bytesTotal)}'
        '${speed == null || speed < 1 ? '' : ' · ${formatSize(speed.round())}/s'}';
  }

  /// What the files in hand are doing, such as "Copying 1 · Checking 1 ·
  /// Uploading 3", or null when none is.
  String? get stageLine {
    final parts = [
      if (waiting > 0) 'Waiting $waiting',
      if (copying > 0) 'Copying $copying',
      if (checking > 0) 'Checking $checking',
      if (uploading > 0) 'Uploading $uploading',
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// Files that still need attention.
  int get problems => failed + blocked;

  int get settled => transferred + recognised + moved + failed;

  /// Files the run was to upload and has not finished, whether it stopped
  /// early or is still going.
  int get unfinished => toUpload > settled ? toUpload - settled : 0;

  /// Files confirmed on the server: everything found, less what failed and
  /// what was still waiting when the run ended.
  int get backedUp {
    final done = found - problems - unfinished;
    return done > 0 ? done : 0;
  }

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
      : backedUp == found
      ? '${formatCount(found)} backed up$_notes'
      : '${formatCount(backedUp)} of ${formatCount(found)} backed up$_notes';

  /// How files were settled without being uploaded, so the count can be
  /// matched against the server: " · 1 already on your server · 2 moved on
  /// your server".
  String get _notes =>
      (recognised == 0
          ? ''
          : ' · ${formatCount(recognised)} already on your server') +
      (moved == 0 ? '' : ' · ${formatCount(moved)} moved on your server');

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
