import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../core/cloud/cloud_backend.dart';
import '../../core/storage/local_cache.dart';
import '../../models.dart';

/// Downloads originals and publishes offline membership only after validation.
class OriginalTransfers {
  OriginalTransfers({required this.client, required this.cache});

  final CloudBackend client;
  final LocalCache? cache;

  static String _originalKey(Account account, CloudFile file) =>
      'original|${account.storageKey}|${file.id ?? file.key}|'
      '${file.modified?.microsecondsSinceEpoch}|${file.size}';

  Future<File?> offlineCopy(Account account, CloudFile file) async {
    final storage = cache;
    if (storage == null) return null;
    final copy = await storage.original(_originalKey(account, file), file.name);
    return await copy.exists() && await copy.length() == file.size
        ? copy
        : null;
  }

  /// Resolve a pathless item against saved membership without a server lookup.
  Future<({File output, CloudFile file})?> _savedCopy(
    Account account,
    CloudFile file,
  ) async {
    if (!file.pending) {
      final output = await offlineCopy(account, file);
      return output == null ? null : (output: output, file: file);
    }
    final storage = cache;
    final id = file.id;
    final revision = file.etag;
    if (storage == null || id == null || revision == null || revision.isEmpty) {
      return null;
    }
    final saved = await storage.readOfflineListing(
      'offline|${account.storageKey}',
    );
    for (final item in saved) {
      if (item.id == id && item.etag == revision && item.size == file.size) {
        final copy = await offlineCopy(account, item);
        if (copy != null) return (output: copy, file: item);
      }
    }
    return null;
  }

  Future<File?> playbackCopy(Account account, CloudFile file) async =>
      (await _savedCopy(account, file))?.output;

  Future<({File output, CloudFile file})> download(
    Account account,
    CloudFile file, {
    required bool offline,
    required void Function() checkSession,
  }) async {
    final storage = cache;
    if (offline && storage == null) {
      throw const CloudException('Downloads need a connected server.');
    }
    checkSession();
    Future<File> publishOffline(CloudFile file, File target) async {
      checkSession();
      final key = 'offline|${account.storageKey}';
      final saved = await storage!.readOfflineListing(key);
      checkSession();
      await storage.writeOfflineListing(key, [
        ...saved.where((f) => f.key != file.key),
        file,
      ]);
      return target;
    }

    if (offline) {
      if (file.pending) {
        final saved = await _savedCopy(account, file);
        checkSession();
        if (saved != null) return saved;
      } else {
        final target = await storage!.original(
          _originalKey(account, file),
          file.name,
        );
        if (await target.exists() && await target.length() == file.size) {
          return (output: await publishOffline(file, target), file: file);
        }
      }
    }
    Directory? transfer;
    try {
      final folder = Directory(
        '${(await getTemporaryDirectory()).path}/ncloud-downloads',
      );
      await folder.create(recursive: true);
      validateName(file.name);
      checkSession();
      if (offline && file.etag?.isNotEmpty != true) {
        throw const CloudException(
          'A file revision is required for safe sync.',
        );
      }
      final response = await client.download(
        account,
        file,
        expectedRevision: offline ? file.etag : null,
      );
      try {
        checkSession();
        final downloaded = response.file;
        if (downloaded.pending ||
            (file.id != null && downloaded.id != file.id)) {
          throw const CloudException(
            'The downloaded item has an invalid location.',
          );
        }
        validateName(downloaded.name);
        file = downloaded;
      } catch (_) {
        await response.stream.listen(null).cancel();
        rethrow;
      }
      transfer = await folder.createTemp('transfer-');
      final output = File('${transfer.path}/${file.name}');
      final sink = output.openWrite();
      try {
        await sink.addStream(
          response.stream.timeout(const Duration(seconds: 45)),
        );
        await sink.flush();
      } finally {
        await sink.close();
      }
      if (await output.length() != file.size) {
        throw const CloudException(
          'Download size did not match the file. Refresh and retry.',
        );
      }
      checkSession();
      if (!offline) return (output: output, file: file);
      final target = await storage!.original(
        _originalKey(account, file),
        file.name,
      );
      checkSession();
      final partial = File('${target.path}.part');
      try {
        await output.copy(partial.path);
        checkSession();
        await partial.rename(target.path);
      } finally {
        if (await partial.exists()) await partial.delete();
      }
      return (output: await publishOffline(file, target), file: file);
    } catch (_) {
      if (transfer != null && await transfer.exists()) {
        await transfer.delete(recursive: true);
      }
      rethrow;
    } finally {
      if (offline && transfer != null && await transfer.exists()) {
        await transfer.delete(recursive: true);
      }
    }
  }
}
