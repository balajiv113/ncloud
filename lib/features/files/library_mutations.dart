import '../../core/cloud/cloud_backend.dart';
import '../../core/storage/file_store.dart';
import '../../models.dart';

/// Applies a batch of library mutations to the initiating account and cache.
class LibraryMutations {
  LibraryMutations({
    required this.client,
    required this.store,
    required this.resolve,
    required this.checkSession,
    required this.onCompleted,
  });

  final CloudBackend client;
  final FileStore store;
  final Future<CloudFile> Function(CloudFile) resolve;
  final void Function() checkSession;
  final void Function() onCompleted;

  Future<void> run(
    List<CloudFile> files,
    String operation, {
    required Account? account,
    List<String>? destination,
    String? newName,
    bool favorite = true,
  }) async {
    if (account == null) {
      throw const CloudException('Sign in to manage files.');
    }
    final resolved = <CloudFile>[];
    for (final file in files) {
      checkSession();
      resolved.add(await resolve(file));
      checkSession();
    }
    for (final file in resolved) {
      checkSession();
      if (file.readOnly) {
        throw const CloudException(
          'This album item is view-only. Manage its original on your server.',
        );
      }
      if (operation == 'move' || operation == 'copy' || operation == 'rename') {
        final target = operation == 'rename'
            ? [...file.path.take(file.path.length - 1), newName!]
            : [...?destination, newName ?? file.name];
        validateName(target.last);
        if (file.isDirectory && pathStartsWith(target, file.path)) {
          throw const CloudException(
            'A folder cannot be placed inside itself.',
          );
        }
        if (operation == 'copy') {
          await client.copy(account, file, target);
        } else {
          await client.move(account, file, target);
        }
        checkSession();
        store.moveTree(file.path, target, copy: operation == 'copy');
      } else if (operation == 'delete') {
        await client.delete(account, file);
        checkSession();
        store.removeTree(file.path);
      } else if (operation == 'favorite') {
        await client.setFavorite(account, file, favorite);
        checkSession();
        store.update(file.key, (f) => f.withFavorite(favorite));
      } else {
        throw const CloudException('This action is not supported.');
      }
      onCompleted();
    }
  }
}
