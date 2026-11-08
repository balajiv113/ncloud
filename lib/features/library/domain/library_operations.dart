import 'dart:async';
import 'dart:io';

import '../../../app/status_sink.dart';
import '../../../core/cloud/cloud_backend.dart';
import '../../../core/storage/file_store.dart';
import '../../../diagnostics.dart';
import '../../../models.dart';
import 'file_resolver.dart';
import 'library_mutations.dart';
import 'original_transfers.dart';

/// Changes to the library and transfers of its files: moving, copying, deleting
/// and favoriting, new folders, uploads, the trash and downloads. One runs at a
/// time ([busy]); each is bound to the account that started it, so a change of
/// account stops it rather than touching the new account's data.
class LibraryOperations {
  LibraryOperations({
    required this.client,
    required this.store,
    required this.originals,
    required this.resolver,
    required this.account,
    required this.disposed,
    required this.status,
    required this.directory,
    required this.refresh,
    required this.onChanged,
  });

  final CloudBackend client;
  final FileStore store;
  final OriginalTransfers originals;
  final FileResolver resolver;
  final Account? Function() account;
  final bool Function() disposed;
  final StatusSink status;

  /// The folder the library is showing, where new folders and uploads go.
  final List<String> Function() directory;

  /// Brings the views up to date after a change. [coversChanged] also drops
  /// remembered album covers. Does nothing further once [current] is false.
  final Future<void> Function({
    required bool coversChanged,
    required bool Function() current,
  })
  refresh;
  final void Function() onChanged;

  bool busy = false;

  /// Progress of the running operation, in files.
  int completed = 0;
  int total = 0;

  /// Applies [operation] (`move`, `copy`, `rename`, `delete` or `favorite`)
  /// to [files]. Returns whether every file succeeded.
  Future<bool> organize(
    List<CloudFile> files,
    String operation, {
    List<String>? destination,
    String? newName,
    bool favorite = true,
  }) async {
    if (busy || files.isEmpty) return false;
    final session = account();
    bool current() => !disposed() && identical(account(), session);
    void checkSession() {
      if (!current()) {
        throw const CloudException(
          'The account changed. Start the operation again.',
        );
      }
    }

    busy = true;
    status.error = null;
    status.notice = null;
    completed = 0;
    total = files.length;
    onChanged();
    Object? failure;
    try {
      await LibraryMutations(
        client: client,
        store: store,
        resolve: resolver.resolve,
        checkSession: checkSession,
        onCompleted: () {
          completed++;
          onChanged();
        },
      ).run(
        files,
        operation,
        account: session,
        destination: destination,
        newName: newName,
        favorite: favorite,
      );
    } catch (e) {
      failure = e;
    }
    try {
      if (!current()) return false;
      await refresh(coversChanged: true, current: current);
      if (!current()) return false;
      if (failure != null) {
        status.error =
            '$completed of $total completed. ${errorMessage(failure)}';
      } else {
        status.notice =
            '$completed ${completed == 1 ? 'item' : 'items'} updated';
      }
      return failure == null;
    } finally {
      busy = false;
      onChanged();
    }
  }

  Future<List<TrashEntry>> trash() => client.trash(account()!);

  Future<void> restore(TrashEntry entry) async {
    if (busy) throw const CloudException('Wait for the current operation.');
    busy = true;
    onChanged();
    final session = account();
    try {
      await client.restore(session!, entry);
      await refresh(
        coversChanged: true,
        current: () => !disposed() && identical(account(), session),
      );
    } finally {
      busy = false;
      onChanged();
    }
  }

  Future<void> favorite(CloudFile file) => _single(() async {
    file = await resolver.resolve(file);
    await client.setFavorite(account()!, file, !file.favorite);
    store.update(file.key, (f) => f.withFavorite(!file.favorite));
  }, file.favorite ? 'Removed from favorites' : 'Added to favorites');

  Future<void> createFolder(String name) => _single(() async {
    validateName(name);
    final folder = directory();
    await client.createFolder(account()!, [...folder, name]);
    store.invalidateFolder(folder);
  }, 'Folder created');

  Future<void> upload(String name, Stream<List<int>> bytes, int size) =>
      _single(() async {
        final folder = directory();
        await client.uploadNew(account()!, [...folder, name], bytes, size);
        store.invalidateFolder(folder);
      }, 'Upload complete');

  /// One change with a success message; a failure becomes the error.
  Future<void> _single(Future<void> Function() change, String success) async {
    if (busy) return;
    busy = true;
    total = 0;
    completed = 0;
    status.error = null;
    status.notice = null;
    onChanged();
    final session = account();
    try {
      await change();
      status.notice = success;
      await refresh(
        coversChanged: false,
        current: () => !disposed() && identical(account(), session),
      );
    } catch (e) {
      status.error = errorMessage(e);
    } finally {
      busy = false;
      onChanged();
    }
  }

  /// Downloads [file]'s original. With [offline] it is kept as a saved offline
  /// original, not in the bounded browsing cache.
  Future<File> download(CloudFile file, {bool offline = false}) async {
    final session = account();
    if (session == null || (offline && originals.cache == null)) {
      throw const CloudException('Downloads need a connected server.');
    }
    if (busy) {
      throw const CloudException('Wait for the current transfer to finish.');
    }
    busy = true;
    total = 0;
    completed = 0;
    onChanged();
    final generation = resolver.generation;
    try {
      void checkSession() {
        if (disposed() || account() != session) {
          throw const CloudException(
            'The account changed. Start the download again.',
          );
        }
      }

      final result = await originals.download(
        session,
        file,
        offline: offline,
        checkSession: checkSession,
      );
      checkSession();
      if (file.pending) {
        resolver.remember(session, file, result.file, generation: generation);
      }
      return result.output;
    } finally {
      busy = false;
      onChanged();
    }
  }
}
