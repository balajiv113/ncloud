import 'package:flutter/foundation.dart';

import '../../../core/cloud/cloud_backend.dart';
import '../../../core/storage/file_store.dart';
import '../../../models.dart';

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
    required bool demo,
    required List<CloudFile> demoFiles,
    required Map<String, List<CloudFile>> demoTrash,
    List<String>? destination,
    String? newName,
    bool favorite = true,
  }) async {
    if (!demo && account == null) {
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
        if (demo) {
          if (demoFiles.any((f) => listEquals(f.path, target))) {
            throw const CloudException(
              'An item with that name already exists.',
            );
          }
          final moved = demoFiles
              .where((f) => pathStartsWith(f.path, file.path))
              .map(
                (f) => f.atPath([...target, ...f.path.skip(file.path.length)]),
              )
              .toList();
          if (operation != 'copy') {
            demoFiles.removeWhere((f) => pathStartsWith(f.path, file.path));
          }
          demoFiles.addAll(moved);
        } else {
          if (operation == 'copy') {
            await client.copy(account!, file, target);
          } else {
            await client.move(account!, file, target);
          }
          checkSession();
          store.moveTree(file.path, target, copy: operation == 'copy');
        }
      } else if (operation == 'delete') {
        if (demo) {
          demoTrash['${file.key}:${DateTime.now().microsecondsSinceEpoch}'] =
              demoFiles
                  .where((f) => pathStartsWith(f.path, file.path))
                  .toList();
          demoFiles.removeWhere((f) => pathStartsWith(f.path, file.path));
        } else {
          await client.delete(account!, file);
          checkSession();
          store.removeTree(file.path);
        }
      } else if (operation == 'favorite') {
        if (demo) {
          for (var i = 0; i < demoFiles.length; i++) {
            if (demoFiles[i].key == file.key) {
              demoFiles[i] = demoFiles[i].withFavorite(favorite);
            }
          }
        } else {
          await client.setFavorite(account!, file, favorite);
          checkSession();
          store.update(file.key, (f) => f.withFavorite(favorite));
        }
      } else {
        throw const CloudException('This action is not supported.');
      }
      onCompleted();
    }
  }
}
