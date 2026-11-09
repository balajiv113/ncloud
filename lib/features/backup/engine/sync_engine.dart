import 'dart:convert';
import 'dart:io';

import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';
import '../platform/folder_access.dart';
import '../state/sync_journal.dart';
import 'backup_preview.dart';
import 'conflict_name.dart';
import 'failure_policy.dart';
import 'fingerprint.dart';
import 'pair_policy.dart';
import 'sync_progress.dart';

export 'sync_progress.dart';

/// Thrown by a stop check when the run should end early, such as when the user
/// pauses or the app leaves the foreground.
class SyncStopped implements Exception {}

/// The most device files one pair may hold. It bounds memory, not time.
const _maxEntries = 300000;
const _maxDepth = 64;

/// A file that keeps failing is left alone after this many runs, until the
/// user retries or the file changes.
const _maxAttempts = 5;

FormatException _tooLarge() => const FormatException(
  'This pair holds more files than can be backed up as one. '
  'Choose a smaller folder.',
);

/// The revision of a server file, which a receipt records after an upload.
/// A server that supplies none cannot be backed up to safely.
String remoteVersion(CloudFile file) {
  if (file.etag?.isNotEmpty != true) {
    throw const FormatException(
      'The server did not supply a file revision. Sync stopped safely.',
    );
  }
  return '${file.etag}|${file.size}';
}

/// A file on the device that the pair's rules allow.
class _Item {
  _Item(this.path, this.entry);

  final List<String> path;
  final DeviceEntry entry;

  /// The path as one string, to look the file up by.
  late final String key = _pathKey(path);

  /// What an earlier run recorded for this path when its version has since
  /// changed: the same file touched or edited, not a new one.
  Receipt? previous;

  /// Whether an earlier run recorded a failure for it, to be cleared on success.
  bool hadFailure = false;
}

/// The key the journal stores a path under.
/// What a run has to do: the files to upload, and how many needed nothing.
class _Plan {
  _Plan(this.todo, this.alreadyBackedUp, this.blocked);

  final List<_Item> todo;
  final int alreadyBackedUp;
  final int blocked;
}

String _pathKey(List<String> path) => jsonEncode(path);

/// Uploads the files of one device folder that the server does not have yet.
///
/// Nothing is ever deleted or overwritten. An upload creates a new file, and a
/// destination that already exists gets a renamed copy. The one change to what
/// the server already holds is a move: when a file moved on the device, the
/// server copy it was uploaded as is moved to match. A receipt is written only
/// after the server confirmed an upload, so an interrupted run resumes where it
/// stopped.
///
/// It is built to stay cheap with a very large library. The server is never
/// asked to list a folder to confirm an upload, receipts are read in groups,
/// and one file that cannot be backed up is recorded and skipped instead of
/// ending the run.
class SyncEngine {
  SyncEngine({
    required this.client,
    required this.access,
    required this.journal,
    required this.progress,
    required this.check,
    required this.onChanged,
    DateTime Function()? clock,
    Future<void> Function(Duration)? pause,
  }) : _clock = clock ?? DateTime.now,
       _pause = pause ?? Future<void>.delayed;

  final CloudBackend client;
  final FolderAccess access;
  final SyncJournal journal;
  final SyncProgress progress;

  /// Throws [SyncStopped] when the run should end. Called between every step.
  final void Function(FolderPair pair) check;
  final void Function() onChanged;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _pause;

  DateTime _notified = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime? _networkChecked;

  /// The paths of every file on the device this run, to tell a file that moved
  /// from one that was copied.
  Set<String> _present = const {};

  void _status(String phase) {
    progress.phase = phase;
    onChanged();
  }

  /// Tells the screen something changed, at most a few times a second, so a
  /// fast run does not spend its time redrawing.
  void _tick() {
    final now = _clock();
    if (now.difference(_notified) < const Duration(milliseconds: 250)) return;
    _notified = now;
    onChanged();
  }

  Future<void> run(Account session, FolderPair pair) async {
    check(pair);
    checkSyncPath(pair.cloudRoot);
    validateConcurrency(pair.uploadConcurrency);
    _status('Checking Wi-Fi');
    await _requireNetwork(pair, fresh: true);
    _status('Reading selected device folder');
    // A complete inventory precedes any transfer, so a permission error is
    // never mistaken for an empty source.
    final local = await _scanDevice(pair);
    progress.found = local.length;
    _present = {for (final item in local) item.key};
    _status('Checking what is already backed up');
    final plan = await _classify(pair, local);
    final todo = plan.todo;
    progress
      ..alreadyBackedUp = plan.alreadyBackedUp
      ..blocked = plan.blocked
      ..toUpload = todo.length
      ..bytesTotal = _bytes(todo);
    _status('Preparing the destination');
    await _ensureCloudRoot(session, pair);
    if (todo.isNotEmpty) {
      _status('Uploading');
      await _upload(session, pair, todo);
    }
    check(pair);
  }

  Future<void> _requireNetwork(FolderPair pair, {bool fresh = false}) async {
    check(pair);
    if (!pair.wifiOnly) return;
    final now = _clock();
    // Asking the phone for every file would cost more than the check is worth.
    if (!fresh &&
        _networkChecked != null &&
        now.difference(_networkChecked!) < const Duration(seconds: 10)) {
      return;
    }
    if (!(await access.conditions()).wifi) {
      throw const FormatException('Waiting for Wi-Fi. Connect and retry.');
    }
    _networkChecked = now;
  }

  /// Every file under the device folder that the pair's rules allow.
  Future<List<_Item>> _scanDevice(FolderPair pair) async {
    final album = pair.folder.kind == DeviceSourceKind.photoAlbum;
    final found = <_Item>[];
    final folders = <List<String>>[[]];
    var visited = 0;
    while (folders.isNotEmpty) {
      check(pair);
      if (++visited > _maxEntries) throw _tooLarge();
      final path = folders.removeLast();
      for (final item in await access.list(pair.folder.token, path)) {
        final child = [...path, item.name];
        checkSyncPath(child);
        if (child.length > _maxDepth || found.length > _maxEntries) {
          throw _tooLarge();
        }
        if (item.directory) {
          if (pair.rules.visits(child)) folders.add(child);
          continue;
        }
        if (!pair.rules.allows(child, contentType: item.contentType)) continue;
        if (item.modified <= 0) {
          throw const FormatException(
            'The folder provider supplies no file modification date.',
          );
        }
        // Photos reports no size, but always a revision to detect changes.
        final sizeKnown =
            item.size >= 0 ||
            (album && item.size == -1 && item.revision?.isNotEmpty == true);
        if (!sizeKnown) {
          throw const FormatException(
            'The folder provider supplies no file size.',
          );
        }
        found.add(_Item(child, item));
      }
    }
    return found;
  }

  /// Works out which files need uploading: those with no receipt for their
  /// current version, newest first so recent photos arrive soonest. Receipts
  /// are read in groups, so the cost grows with the library, not with the
  /// library times the number of queries.
  Future<_Plan> _classify(FolderPair pair, List<_Item> local) async {
    final todo = <_Item>[];
    var alreadyBackedUp = 0;
    var blocked = 0;
    final anyFailures = await journal.failureCount(pair.id) > 0;
    const group = 400;
    for (var start = 0; start < local.length; start += group) {
      check(pair);
      final chunk = local.sublist(
        start,
        (start + group).clamp(0, local.length),
      );
      final receipts = await journal.receiptsFor(pair.id, [
        for (final item in chunk) item.path,
      ]);
      final failures = anyFailures
          ? await journal.failuresFor(pair.id, [
              for (final item in chunk) item.path,
            ])
          : const <String, StoredFailure>{};
      for (final item in chunk) {
        final version = item.entry.version;
        if (receipts[item.key]?.version == version) {
          alreadyBackedUp++;
          continue;
        }
        final failure = failures[item.key];
        if (failure != null) {
          item.hadFailure = true;
          if (failure.version == version && failure.attempts >= _maxAttempts) {
            blocked++;
            continue;
          }
        }
        item.previous = receipts[item.key];
        todo.add(item);
      }
    }
    todo.sort((a, b) => b.entry.modified.compareTo(a.entry.modified));
    return _Plan(todo, alreadyBackedUp, blocked);
  }

  static int _bytes(List<_Item> items) =>
      items.fold(0, (sum, i) => sum + (i.entry.size > 0 ? i.entry.size : 0));

  /// Works out what a run would do, without doing any of it. It reads the
  /// device and the saved records and asks the server one question, whether
  /// the destination exists; it uploads nothing, creates nothing and records
  /// nothing.
  Future<BackupPreview> preview(Account session, FolderPair pair) async {
    check(pair);
    checkSyncPath(pair.cloudRoot);
    validateConcurrency(pair.uploadConcurrency);
    final local = await _scanDevice(pair);
    final plan = await _classify(pair, local);
    final shares = <String, (int, int)>{};
    DateTime? oldest;
    DateTime? newest;
    for (final item in plan.todo) {
      final folder = item.path.length > 1 ? item.path.first : pair.folder.name;
      final share = shares[folder] ?? (0, 0);
      shares[folder] = (
        share.$1 + 1,
        share.$2 + (item.entry.size > 0 ? item.entry.size : 0),
      );
      final when = DateTime.fromMillisecondsSinceEpoch(item.entry.modified);
      if (oldest == null || when.isBefore(oldest)) oldest = when;
      if (newest == null || when.isAfter(newest)) newest = when;
    }
    bool? exists;
    try {
      exists = (await client.stat(session, pair.cloudRoot)) != null;
    } on Object {
      // The preview is still useful without the server.
    }
    final folders =
        [
          for (final MapEntry(key: name, value: share) in shares.entries)
            FolderShare(name, share.$1, share.$2),
        ]..sort(
          (a, b) => b.bytes != a.bytes
              ? b.bytes.compareTo(a.bytes)
              : b.files.compareTo(a.files),
        );
    return BackupPreview(
      found: local.length,
      alreadyBackedUp: plan.alreadyBackedUp,
      toUpload: plan.todo.length,
      bytes: _bytes(plan.todo),
      blocked: plan.blocked,
      folders: folders,
      oldest: oldest,
      newest: newest,
      destinationExists: exists,
    );
  }

  /// Makes sure the pair's cloud folder exists, creating it when it does not.
  Future<void> _ensureCloudRoot(Account session, FolderPair pair) async {
    final root = await client.stat(session, pair.cloudRoot);
    check(pair);
    if (root == null) {
      await client.ensureFolder(session, pair.cloudRoot);
    } else if (!root.isDirectory) {
      throw const FormatException(
        'A file blocks the selected folder name on the server. Choose another destination.',
      );
    }
  }

  Future<void> _upload(
    Account session,
    FolderPair pair,
    List<_Item> todo,
  ) async {
    progress.begin(_clock());
    final worker = _Uploader(this, session, pair);
    try {
      await runConcurrently(todo, pair.uploadConcurrency, worker.upload);
    } finally {
      await worker.finish();
    }
  }
}

/// One run's uploads: sends each file, with retries, and records the outcome.
class _Uploader {
  _Uploader(this.engine, this.session, this.pair);

  final SyncEngine engine;
  final Account session;
  final FolderPair pair;
  final FailureBreaker _breaker = FailureBreaker();

  /// Folders known to exist, so a folder is checked once however many files go
  /// into it. A creation in progress is shared by the workers waiting on it.
  final Map<String, Future<void>> _folders = {};

  final List<Receipt> _pending = [];
  DateTime _flushed = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _saved = DateTime.fromMillisecondsSinceEpoch(0);
  Future<void> _writing = Future<void>.value();

  CloudBackend get _client => engine.client;
  FolderAccess get _access => engine.access;
  SyncJournal get _journal => engine.journal;
  SyncProgress get _progress => engine.progress;

  Future<void> upload(_Item item) async {
    engine.check(pair);
    for (var attempt = 0; ; attempt++) {
      try {
        await _send(item);
        _breaker.succeeded();
        if (item.hadFailure) await _journal.clearFailure(pair.id, item.path);
        return;
      } on SyncStopped {
        rethrow;
      } on Object catch (error) {
        final kind = classifyFailure(error);
        if (kind == FailureKind.fatal) rethrow;
        if (kind == FailureKind.transient) {
          final wait = retryDelay(attempt);
          if (wait != null) {
            await _wait(wait);
            continue;
          }
        }
        await _fail(
          item,
          error,
          attempt + 1,
          connection: kind == FailureKind.transient,
        );
        return;
      }
    }
  }

  /// Waits for [duration] in short steps, so a stop request is still heard.
  Future<void> _wait(Duration duration) async {
    var left = duration;
    const step = Duration(milliseconds: 500);
    while (left > Duration.zero) {
      engine.check(pair);
      final now = left < step ? left : step;
      await engine._pause(now);
      left -= now;
    }
  }

  /// Records that [item] could not be backed up and moves on. A run that keeps
  /// failing for a reason that is not about the file stops instead.
  Future<void> _fail(
    _Item item,
    Object error,
    int attempts, {
    required bool connection,
  }) async {
    final failure = describeFileFailure(item.path, error, attempts: attempts);
    _progress.failed++;
    await _journal.recordFailure(pair.id, failure, item.entry.version);
    if (_breaker.failed(failure.message, connection: connection)) {
      throw CloudException(_breaker.message, retryable: connection);
    }
  }

  Future<void> _send(_Item item) async {
    final path = item.path;
    final file = item.entry;
    await engine._requireNetwork(pair);
    _progress.current = file.name;
    engine._tick();
    File? staged;
    try {
      staged = await _access.export(pair.folder.token, path, file);
      engine.check(pair);
      final size = await staged.length();
      if (file.size >= 0 && size != file.size) {
        throw const FormatException(
          'The source changed while preparing it. Run again.',
        );
      }
      final fingerprint = await fingerprintOf(staged);
      engine.check(pair);
      if (await _sameFile(item, fingerprint, size, staged)) return;
      // The same content may already be on the server under another path: a
      // photo that moved on the device, or a copy of one. Recognise it.
      if (await _reuseKnown(item, fingerprint, size)) return;
      var target = path;
      for (var renamed = 0; ; renamed++) {
        await _ensureParents(target);
        engine.check(pair);
        await engine._requireNetwork(pair);
        try {
          final result = await _client.uploadNew(
            session,
            [...pair.cloudRoot, ...target],
            staged.openRead(),
            size,
            sha1: fingerprint,
            modified: DateTime.fromMillisecondsSinceEpoch(file.modified),
          );
          final etag = result.etag;
          if (etag == null || etag.isEmpty) {
            throw const FormatException(
              'The server did not supply a file revision. Sync stopped safely.',
            );
          }
          await _record(item, target, '$etag|$size', fingerprint, size);
          _progress.uploaded(size, engine._clock());
          engine._tick();
          return;
        } on CloudException catch (error) {
          if (error.statusCode != 412) rethrow;
          // Something is already there. The same file means an earlier run
          // uploaded it and lost its receipt; anything else keeps both.
          final existing = await _client.stat(session, [
            ...pair.cloudRoot,
            ...target,
          ]);
          if (existing != null &&
              !existing.isDirectory &&
              existing.size == size &&
              existing.etag?.isNotEmpty == true &&
              await _holds(existing, [
                ...pair.cloudRoot,
                ...target,
              ], fingerprint)) {
            await _record(
              item,
              target,
              '${existing.etag}|${existing.size}',
              fingerprint,
              size,
            );
            _progress.wasOnServer(size);
            engine._tick();
            return;
          }
          if (renamed >= 3) {
            throw CloudException(
              'No free name was found for ${path.last} on the server.',
            );
          }
          target = _conflict(target);
        }
      }
    } finally {
      if (staged != null) await _access.discard(staged);
    }
  }

  /// Handles a file this backup stored before and whose version has changed.
  ///
  /// If the content is the same, only the device's bookkeeping changed (a
  /// photo that was touched): the receipt is renewed and nothing is uploaded.
  /// If the content changed, it is an edit: when the server still holds what
  /// was uploaded, the new content becomes a new version of that same file.
  /// When the server copy is gone or changed this returns false, and the file
  /// is uploaded as new, keeping both.
  Future<bool> _sameFile(
    _Item item,
    String fingerprint,
    int size,
    File staged,
  ) async {
    final before = item.previous;
    if (before == null) return false;
    if (before.fingerprint == fingerprint) {
      await _record(
        item,
        before.target,
        before.targetVersion,
        fingerprint,
        size,
      );
      _progress.wasOnServer(size);
      engine._tick();
      return true;
    }
    final at = [...pair.cloudRoot, ...before.target];
    final here = await _client.stat(session, at);
    final etag = here?.etag;
    if (here == null ||
        here.isDirectory ||
        etag == null ||
        etag.isEmpty ||
        !before.targetVersion.startsWith('$etag|')) {
      return false;
    }
    engine.check(pair);
    await engine._requireNetwork(pair);
    try {
      final result = await _client.uploadNew(
        session,
        at,
        staged.openRead(),
        size,
        sha1: fingerprint,
        modified: DateTime.fromMillisecondsSinceEpoch(item.entry.modified),
        replacing: etag,
      );
      final next = result.etag;
      if (next == null || next.isEmpty) {
        throw const FormatException(
          'The server did not supply a file revision. Sync stopped safely.',
        );
      }
      await _record(item, before.target, '$next|$size', fingerprint, size);
      _progress.uploaded(size, engine._clock());
      engine._tick();
      return true;
    } on CloudException catch (error) {
      if (error.statusCode == 412) return false;
      rethrow;
    }
  }

  /// Handles a file whose content this backup has already stored.
  ///
  /// If the earlier file is still on the device, this is a copy: it is recorded
  /// against the same server file and nothing is uploaded. If the earlier file
  /// is gone, the file moved, and the server copy is moved to match. A move only
  /// happens when the server still holds exactly what was uploaded and the new
  /// place is free; otherwise this returns false and the file is uploaded.
  Future<bool> _reuseKnown(_Item item, String fingerprint, int size) async {
    final known = [
      // Receipts still waiting to be saved count: two identical files in one
      // run must not both be uploaded.
      for (final r in _pending)
        if (r.fingerprint == fingerprint) r,
      ...await _journal.receiptsWithFingerprint(pair.id, fingerprint),
    ];
    final others = [
      for (final r in known)
        if (_pathKey(r.path) != item.key) r,
    ];
    if (others.isEmpty) return false;
    final stillThere = others.where(
      (r) => engine._present.contains(_pathKey(r.path)),
    );
    if (stillThere.isNotEmpty) {
      final original = stillThere.first;
      await _record(
        item,
        original.target,
        original.targetVersion,
        fingerprint,
        size,
      );
      _progress.wasOnServer(size);
      engine._tick();
      return true;
    }
    final earlier = others.first;
    final from = [...pair.cloudRoot, ...earlier.target];
    final here = await _client.stat(session, from);
    final unchanged =
        here != null &&
        !here.isDirectory &&
        (here.sha1 == fingerprint ||
            (here.sha1 == null &&
                '${here.etag}|${here.size}' == earlier.targetVersion));
    if (!unchanged) return false;
    final destination = item.path;
    await _ensureParents(destination);
    engine.check(pair);
    try {
      await _client.move(
        session,
        CloudFile(path: from, name: from.last, isDirectory: false),
        [...pair.cloudRoot, ...destination],
      );
    } on CloudException catch (error) {
      // Something is in the way. Upload as usual, which keeps both.
      if (error.statusCode == 412) return false;
      rethrow;
    }
    await _journal.moveReceipt(
      pair.id,
      earlier.path,
      Receipt(
        path: item.path,
        version: item.entry.version,
        target: destination,
        targetVersion: earlier.targetVersion,
        fingerprint: fingerprint,
        size: size,
      ),
    );
    _progress.wasMoved(size);
    engine._tick();
    return true;
  }

  /// Whether the server file is exactly [fingerprint]. A file uploaded by an
  /// older version carries no checksum, so its content is read back and
  /// compared; that is slower, but it is the only way to be sure it is the same
  /// file and not a different one with the same name and size.
  Future<bool> _holds(
    RemoteStat existing,
    List<String> path,
    String fingerprint,
  ) async {
    if (existing.sha1 != null) return existing.sha1 == fingerprint;
    final download = await _client.download(
      session,
      CloudFile(path: path, name: path.last, isDirectory: false),
    );
    return await fingerprintOfStream(download.stream) == fingerprint;
  }

  List<String> _conflict(List<String> path) {
    _progress.conflicts++;
    return conflictName(path, 'device');
  }

  /// Makes sure every folder above [target] exists, checking each folder once.
  Future<void> _ensureParents(List<String> target) async {
    for (var depth = 1; depth < target.length; depth++) {
      final folder = target.take(depth).toList();
      final key = _pathKey(folder);
      final known = _folders[key];
      if (known != null) {
        await known;
        continue;
      }
      final creating = _ensureFolder(folder);
      _folders[key] = creating;
      try {
        await creating;
      } on Object {
        // Let the next file try again.
        _folders.remove(key);
        rethrow;
      }
    }
  }

  Future<void> _ensureFolder(List<String> folder) async {
    final path = [...pair.cloudRoot, ...folder];
    final found = await _client.stat(session, path);
    if (found == null) {
      await _client.ensureFolder(session, path);
    } else if (!found.isDirectory) {
      throw const FormatException(
        'A file blocks a destination folder. Choose another destination.',
      );
    }
  }

  Future<void> _record(
    _Item item,
    List<String> target,
    String version,
    String fingerprint,
    int size,
  ) async {
    _pending.add(
      Receipt(
        path: item.path,
        version: item.entry.version,
        target: target,
        targetVersion: version,
        fingerprint: fingerprint,
        size: size,
      ),
    );
    final now = engine._clock();
    if (_pending.length >= 25 ||
        now.difference(_flushed) > const Duration(seconds: 3)) {
      await _flush();
    }
    if (now.difference(_saved) > const Duration(seconds: 2)) {
      _saved = now;
      await _journal.writeState(pair.id, {
        ..._progress.toJson(),
        'phase': _progress.phase,
      });
    }
  }

  /// Writes the receipts gathered so far, one batch at a time.
  Future<void> _flush() {
    final batch = List.of(_pending);
    _pending.clear();
    _flushed = engine._clock();
    return _writing = _writing.then((_) => _journal.confirmAll(pair.id, batch));
  }

  /// Saves what is left, whether the run finished or stopped.
  Future<void> finish() async {
    await _flush();
    await _writing;
  }
}

/// Runs [work] on every item, at most [concurrency] at a time. The first
/// failure stops new work and is rethrown; a real failure outranks a stop.
Future<void> runConcurrently<T>(
  List<T> items,
  int concurrency,
  Future<void> Function(T item) work,
) async {
  var next = 0;
  Object? failure;
  StackTrace? failureStack;
  Future<void> worker() async {
    while (failure == null && next < items.length) {
      try {
        await work(items[next++]);
      } on Object catch (e, stack) {
        if (failure == null || failure is SyncStopped) {
          failure = e;
          failureStack = stack;
        }
      }
    }
  }

  await Future.wait(List.generate(concurrency, (_) => worker()));
  if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
}
