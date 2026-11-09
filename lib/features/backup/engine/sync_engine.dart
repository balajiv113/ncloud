import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';
import 'conflict_name.dart';
import '../platform/folder_access.dart';
import 'pair_policy.dart';
import '../state/sync_journal.dart';

/// Thrown by a stop check when the run should end early, such as when the user
/// pauses or the app leaves the foreground.
class SyncStopped implements Exception {}

/// What the running backup is doing, for the screen and the notification.
class SyncProgress {
  String phase = '';

  /// Files uploaded and confirmed on the server during this run.
  int transferred = 0;

  /// Uploads renamed because their destination already existed.
  int conflicts = 0;

  void reset() {
    phase = '';
    transferred = 0;
    conflicts = 0;
  }
}

const _maxEntries = 100000;
const _maxDepth = 64;

FormatException _tooLarge() =>
    const FormatException('This pair exceeds the supported scan size.');

String _key(List<String> path) => jsonEncode(path);

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

/// Uploads the files of one device folder that the server does not have yet.
///
/// Every transfer creates a new file: nothing is deleted, overwritten, moved
/// or edited, and a destination that already exists gets a renamed copy. A
/// receipt is written only after the server confirmed an upload, so an
/// interrupted run resumes where it stopped.
class SyncEngine {
  SyncEngine({
    required this.client,
    required this.access,
    required this.journal,
    required this.progress,
    required this.check,
    required this.onChanged,
  });

  final CloudBackend client;
  final FolderAccess access;
  final SyncJournal journal;
  final SyncProgress progress;

  /// Throws [SyncStopped] when the run should end. Called between every step.
  final void Function(FolderPair pair) check;
  final void Function() onChanged;

  void _status(String phase) {
    progress.phase = phase;
    onChanged();
  }

  Future<void> run(Account session, FolderPair pair) async {
    check(pair);
    checkSyncPath(pair.cloudRoot);
    validateConcurrency(pair.uploadConcurrency);
    _status('Checking Wi-Fi');
    await _requireNetwork(pair);
    _status('Reading selected device folder');
    // A complete inventory precedes any transfer, so a permission error is
    // never mistaken for an empty source.
    final local = await _scanDevice(pair);
    _status('Reading cloud destination');
    await _ensureCloudRoot(session, pair);
    final remote = await _scanCloud(session, pair);
    await _upload(session, pair, local, remote);
    check(pair);
  }

  Future<void> _requireNetwork(FolderPair pair) async {
    check(pair);
    if (!pair.wifiOnly) return;
    if (!(await access.conditions()).wifi) {
      throw const FormatException('Waiting for Wi-Fi. Connect and retry.');
    }
  }

  /// Every file under the device folder that the pair's rules allow.
  Future<Map<String, (List<String>, DeviceEntry)>> _scanDevice(
    FolderPair pair,
  ) async {
    final album = pair.folder.kind == DeviceSourceKind.photoAlbum;
    final found = <String, (List<String>, DeviceEntry)>{};
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
        found[_key(child)] = (child, item);
      }
    }
    return found;
  }

  /// Makes sure the pair's cloud folder exists, creating it when it does not.
  Future<void> _ensureCloudRoot(Account session, FolderPair pair) async {
    final children = (await client.listFolder(session, pair.remote)).children;
    check(pair);
    final folder = children
        .where((file) => file.name == pair.folder.name)
        .singleOrNull;
    if (folder == null) {
      await client.createFolder(session, pair.cloudRoot);
    } else if (!folder.isDirectory) {
      throw const FormatException(
        'A file blocks the selected folder name on the server. Choose another destination.',
      );
    }
  }

  /// Every file already under the pair's cloud folder that its rules allow.
  Future<Map<String, (List<String>, CloudFile)>> _scanCloud(
    Account session,
    FolderPair pair,
  ) async {
    final found = <String, (List<String>, CloudFile)>{};
    final folders = <List<String>>[[]];
    var visited = 0;
    while (folders.isNotEmpty) {
      check(pair);
      if (++visited > _maxEntries) throw _tooLarge();
      final path = folders.removeLast();
      final listing = await client.listFolder(session, [
        ...pair.cloudRoot,
        ...path,
      ]);
      for (final item in listing.children) {
        // Never follow a listing outside the folder that was requested.
        final expected = [...pair.cloudRoot, ...path, item.name];
        checkSyncPath(expected);
        if (_key(expected) != _key(item.path) || item.albumReference != null) {
          throw const FormatException(
            'The server returned an unexpected file path.',
          );
        }
        final child = [...path, item.name];
        if (child.length > _maxDepth || found.length > _maxEntries) {
          throw _tooLarge();
        }
        if (item.isDirectory) {
          if (pair.rules.visits(child)) folders.add(child);
          continue;
        }
        if (!pair.rules.allows(child, contentType: item.contentType)) continue;
        remoteVersion(item);
        found[_key(child)] = (child, item);
      }
    }
    return found;
  }

  Future<void> _upload(
    Account session,
    FolderPair pair,
    Map<String, (List<String>, DeviceEntry)> local,
    Map<String, (List<String>, CloudFile)> remote,
  ) async {
    final uploader = _Uploader(this, session, pair, remote);
    await runConcurrently(
      local.values.toList(),
      pair.uploadConcurrency,
      uploader.upload,
    );
  }
}

/// One run's uploads: decides each file's destination and sends it.
class _Uploader {
  _Uploader(this.engine, this.session, this.pair, this.remote);

  final SyncEngine engine;
  final Account session;
  final FolderPair pair;
  final Map<String, (List<String>, CloudFile)> remote;

  /// Destinations chosen by uploads still in progress.
  final Set<String> _reserved = {};

  /// Folder creation is serialized so parallel uploads do not race on it.
  Future<void> _folders = Future<void>.value();

  CloudBackend get _client => engine.client;
  FolderAccess get _access => engine.access;
  SyncJournal get _journal => engine.journal;

  Future<void> upload((List<String>, DeviceEntry) entry) async {
    final (path, file) = entry;
    engine.check(pair);
    if (await _alreadyUploaded(path, file)) return;
    var target = path;
    while (remote.containsKey(_key(target)) ||
        _reserved.contains(_key(target))) {
      target = _conflict(target);
    }
    _reserved.add(_key(target));
    await engine._requireNetwork(pair);
    engine._status('Uploading ${file.name}');
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
      await _ensureParents(target);
      engine.check(pair);
      await engine._requireNetwork(pair);
      await _client.uploadNew(
        session,
        [...pair.cloudRoot, ...target],
        staged.openRead(),
        size,
      );
      final confirmed = await _confirm(target, size);
      final version = remoteVersion(confirmed);
      await _journal.confirm(pair.id, path, file.version, target, version);
      remote[_key(target)] = (target, confirmed);
      engine.progress.transferred++;
      await _journal.writeState(pair.id, {
        'transferred': engine.progress.transferred,
        'phase': engine.progress.phase,
      });
      engine.onChanged();
    } finally {
      if (staged != null) await _access.discard(staged);
    }
  }

  /// Whether a receipt shows this exact file was already uploaded and the
  /// server still has it unchanged.
  Future<bool> _alreadyUploaded(List<String> path, DeviceEntry file) async {
    final receipt = await _journal.receipt(pair.id, 'local', path);
    if (receipt == null || receipt['version'] != file.version) return false;
    final target = (jsonDecode(receipt['target'] as String) as List)
        .cast<String>();
    final onServer = remote[_key(target)];
    return onServer != null &&
        remoteVersion(onServer.$2) == receipt['target_version'];
  }

  List<String> _conflict(List<String> path) {
    engine.progress.conflicts++;
    return conflictName(path, 'device');
  }

  /// The server's record of the upload, which must match what was sent.
  Future<CloudFile> _confirm(List<String> target, int size) async {
    final listing = await _client.listFolder(session, [
      ...pair.cloudRoot,
      ...target.take(target.length - 1),
    ]);
    final confirmed = listing.children
        .where((item) => item.name == target.last && !item.isDirectory)
        .single;
    if (confirmed.size != size) {
      throw const FormatException(
        'Upload size was not confirmed. Run again to reconcile.',
      );
    }
    return confirmed;
  }

  Future<void> _ensureParents(List<String> target) async {
    final previous = _folders;
    final ready = Completer<void>();
    _folders = ready.future;
    try {
      await previous;
      var parent = List.of(pair.cloudRoot);
      for (final segment in target.take(target.length - 1)) {
        engine.check(pair);
        final children = (await _client.listFolder(session, parent)).children;
        engine.check(pair);
        final match = children
            .where((file) => file.name == segment)
            .singleOrNull;
        parent = [...parent, segment];
        if (match == null) {
          await _client.createFolder(session, parent);
        } else if (!match.isDirectory) {
          throw const FormatException(
            'A file blocks a destination folder. Choose another destination.',
          );
        }
      }
    } finally {
      ready.complete();
    }
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
