import 'dart:convert';

import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';
import '../platform/folder_access.dart';
import '../state/sync_journal.dart';

/// A phone album or folder that can be cleared, with what is in it.
class RemovalTarget {
  const RemovalTarget(this.name, this.path, this.files, this.bytes);

  final String name;

  /// Where it is under the backup's source: empty for the files at the top.
  final List<String> path;
  final int files;

  /// Total size, or 0 when the platform does not say.
  final int bytes;
}

/// Why a file stays on the phone.
enum KeepReason {
  /// The backup has no record of it, or it changed after it was backed up.
  notBackedUp,

  /// The server no longer has it, or has something else under that name.
  notOnServer,

  /// It belongs to a photo whose other parts could not be verified.
  partOfUnverified,
}

class KeptFile {
  const KeptFile(this.path, this.reason);

  final List<String> path;
  final KeepReason reason;
}

/// One file that is safe to remove.
class RemovableFile {
  const RemovableFile(this.path, this.entry, this.receipt);

  final List<String> path;
  final DeviceEntry entry;
  final Receipt receipt;
}

/// What clearing one album or folder would do. Nothing is changed by making it.
class RemovalPlan {
  const RemovalPlan({
    required this.target,
    required this.removable,
    required this.kept,
  });

  final RemovalTarget target;

  /// Files that are on the server, unchanged, exactly as backed up.
  final List<RemovableFile> removable;
  final List<KeptFile> kept;

  int get bytes => removable.fold(
    0,
    (sum, f) => sum + (f.entry.size > 0 ? f.entry.size : 0),
  );

  int keptFor(KeepReason reason) =>
      kept.where((k) => k.reason == reason).length;

  bool get isEmpty => removable.isEmpty;
}

/// The outcome of removing, which may have stopped early.
class RemovalResult {
  const RemovalResult({
    required this.removed,
    required this.bytes,
    required this.stopped,
    this.reason,
  });

  final int removed;
  final int bytes;

  /// Whether it ended before everything planned was removed.
  final bool stopped;
  final String? reason;
}

String _bare(String? etag) => (etag ?? '').replaceAll('"', '');

/// The albums or folders under [pair]'s source, each with its file count.
Future<List<RemovalTarget>> removalTargets(
  FolderAccess access,
  FolderPair pair,
) async {
  final token = pair.folder.token;
  final top = await access.list(token, const []);
  final targets = <RemovalTarget>[];
  Future<void> add(
    String name,
    List<String> path,
    List<DeviceEntry> items,
  ) async {
    final files = items.where((e) => !e.directory).toList();
    if (files.isEmpty) return;
    targets.add(
      RemovalTarget(
        name,
        path,
        files.length,
        files.fold(0, (sum, e) => sum + (e.size > 0 ? e.size : 0)),
      ),
    );
  }

  for (final folder in top.where((e) => e.directory)) {
    await add(folder.name, [
      folder.name,
    ], await access.list(token, [folder.name]));
  }
  await add(pair.folder.name, const [], top);
  targets.sort((a, b) {
    if (a.bytes != b.bytes) return b.bytes.compareTo(a.bytes);
    if (a.files != b.files) return b.files.compareTo(a.files);
    return a.name.compareTo(b.name);
  });
  return targets;
}

/// Works out which files of [target] may be removed, by checking each against
/// the server now: the backup must have recorded the file as it is on the
/// phone, and the server must still hold what was uploaded. Nothing else is
/// ever offered. A photo made of several files is only removable when every one
/// of them is.
Future<RemovalPlan> planRemoval({
  required CloudBackend client,
  required FolderAccess access,
  required SyncJournal journal,
  required Account session,
  required FolderPair pair,
  required RemovalTarget target,
}) async {
  final listed = await access.list(pair.folder.token, target.path);
  final files = [
    for (final entry in listed)
      if (!entry.directory) (path: [...target.path, entry.name], entry: entry),
  ];
  return verify(
    client: client,
    journal: journal,
    session: session,
    pair: pair,
    target: target,
    files: files,
  );
}

/// The checks of [planRemoval], applied to files already listed.
Future<RemovalPlan> verify({
  required CloudBackend client,
  required SyncJournal journal,
  required Account session,
  required FolderPair pair,
  required RemovalTarget target,
  required List<({List<String> path, DeviceEntry entry})> files,
}) async {
  final receipts = <String, Receipt>{};
  for (var i = 0; i < files.length; i += 400) {
    receipts.addAll(
      await journal.receiptsFor(pair.id, [
        for (final f in files.skip(i).take(400)) f.path,
      ]),
    );
  }
  final folders = <String, Map<String, CloudFile>>{};
  Future<Map<String, CloudFile>> folder(List<String> parent) async {
    final key = jsonEncode(parent);
    final known = folders[key];
    if (known != null) return known;
    try {
      final listing = await client.listFolder(session, [
        ...pair.cloudRoot,
        ...parent,
      ]);
      return folders[key] = {for (final c in listing.children) c.name: c};
    } on CloudException catch (error) {
      if (error.statusCode != 404) rethrow;
      return folders[key] = const {};
    }
  }

  final reasons = <String, KeepReason>{};
  final receiptOf = <String, Receipt>{};
  for (final f in files) {
    final key = jsonEncode(f.path);
    final receipt = receipts[key];
    if (receipt == null || receipt.version != f.entry.version) {
      reasons[key] = KeepReason.notBackedUp;
      continue;
    }
    final parent = receipt.target.take(receipt.target.length - 1).toList();
    final onServer = (await folder(parent))[receipt.target.last];
    final parts = receipt.targetVersion.split('|');
    final size = receipt.size ?? int.tryParse(parts.last);
    if (onServer == null ||
        onServer.isDirectory ||
        _bare(onServer.etag) != _bare(parts.first) ||
        (size != null && onServer.size != size)) {
      reasons[key] = KeepReason.notOnServer;
      continue;
    }
    receiptOf[key] = receipt;
  }

  // Files that belong to one photo go together or not at all.
  final blocked = <String>{
    for (final f in files)
      if (f.entry.id != null && !receiptOf.containsKey(jsonEncode(f.path)))
        f.entry.id!,
  };
  final removable = <RemovableFile>[];
  final kept = <KeptFile>[];
  for (final f in files) {
    final key = jsonEncode(f.path);
    final receipt = receiptOf[key];
    if (receipt == null) {
      kept.add(KeptFile(f.path, reasons[key]!));
    } else if (f.entry.id != null && blocked.contains(f.entry.id)) {
      kept.add(KeptFile(f.path, KeepReason.partOfUnverified));
    } else {
      removable.add(RemovableFile(f.path, f.entry, receipt));
    }
  }
  return RemovalPlan(target: target, removable: removable, kept: kept);
}

/// Files per system confirmation. Small enough to read about, large enough
/// that a big album is not hundreds of prompts.
const removalBatch = 200;

/// Moves the removable files of [plan] to the phone's trash, a batch at a time.
/// Each batch is checked against the server again just before the phone is
/// asked, so what was true at planning time is not taken on trust. It stops
/// when asked, when the user declines a prompt, or when a batch can no longer
/// be verified; what was already removed stays removed.
Future<RemovalResult> removeFromPhone({
  required CloudBackend client,
  required FolderAccess access,
  required RemovableAccess remover,
  required SyncJournal journal,
  required Account session,
  required FolderPair pair,
  required RemovalPlan plan,
  void Function(int removed, int total)? onProgress,
  bool Function()? shouldStop,
}) async {
  final all = plan.removable;
  var removed = 0;
  var bytes = 0;
  onProgress?.call(0, all.length);
  for (var i = 0; i < all.length; i += removalBatch) {
    if (shouldStop?.call() ?? false) {
      return RemovalResult(
        removed: removed,
        bytes: bytes,
        stopped: true,
        reason: 'Stopped. What was removed stays removed.',
      );
    }
    final batch = all.skip(i).take(removalBatch).toList();
    // Look again: the phone and the server may both have changed.
    final fresh = await access.list(pair.folder.token, plan.target.path);
    final byName = {for (final e in fresh) e.name: e};
    final again = <({List<String> path, DeviceEntry entry})>[];
    for (final f in batch) {
      final entry = byName[f.path.last];
      if (entry != null) again.add((path: f.path, entry: entry));
    }
    final checked = await verify(
      client: client,
      journal: journal,
      session: session,
      pair: pair,
      target: plan.target,
      files: again,
    );
    if (checked.removable.length != batch.length) {
      return RemovalResult(
        removed: removed,
        bytes: bytes,
        stopped: true,
        reason:
            'Some files changed since the check, so nothing more was removed. '
            'Check again.',
      );
    }
    final gone = await remover.moveToTrash(pair.folder.token, [
      for (final f in checked.removable) (path: f.path, entry: f.entry),
    ]);
    removed += gone.length;
    for (final f in checked.removable) {
      if (gone.any((p) => jsonEncode(p) == jsonEncode(f.path))) {
        bytes += f.entry.size > 0 ? f.entry.size : 0;
      }
    }
    onProgress?.call(removed, all.length);
    if (gone.length != batch.length) {
      return RemovalResult(
        removed: removed,
        bytes: bytes,
        stopped: true,
        reason: 'Stopped: the phone did not remove the last batch.',
      );
    }
  }
  return RemovalResult(removed: removed, bytes: bytes, stopped: false);
}
