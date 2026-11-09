import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../../core/cloud/cloud_backend.dart';
import '../../models.dart';

/// The short videos of Live Photos, downloaded when first played and kept as
/// files so they replay instantly. Only the most recent few are kept.
class LivePhotoClips {
  LivePhotoClips({
    required this.client,
    required this.directory,
    this.keep = 20,
  });

  final CloudBackend client;
  final Future<Directory> Function() directory;
  final int keep;
  final Map<String, Future<File>> _pending = {};

  /// The clip for [file], downloading it unless it was already saved for this
  /// version of the photo. Concurrent requests share one download.
  Future<File> clip(Account account, CloudFile file) {
    final name = _name(file);
    return _pending.putIfAbsent(name, () async {
      try {
        final folder = await directory();
        final existing = [
          for (final extension in _extensions)
            File('${folder.path}/$name$extension'),
        ];
        for (final saved in existing) {
          if (await saved.exists()) return saved;
        }
        final bytes = await client.livePhotoVideo(account, file);
        await folder.create(recursive: true);
        final saved = File('${folder.path}/$name${extensionFor(bytes)}');
        await saved.writeAsBytes(bytes, flush: true);
        await _trim(folder);
        return saved;
      } finally {
        unawaited(_pending.remove(name));
      }
    });
  }

  Future<void> _trim(Directory folder) async {
    final files = <File, DateTime>{};
    await for (final entry in folder.list()) {
      if (entry is File) files[entry] = (await entry.stat()).modified;
    }
    if (files.length <= keep) return;
    final oldest = files.keys.toList()
      ..sort((a, b) => files[a]!.compareTo(files[b]!));
    for (final file in oldest.take(files.length - keep)) {
      await file.delete();
    }
  }

  static const _extensions = ['.mov', '.mp4'];

  /// iPhone clips are QuickTime movies and Android's are MP4; the platform
  /// players decide how to read a file partly from its extension.
  static String extensionFor(Uint8List bytes) {
    final brand = bytes.length >= 12
        ? String.fromCharCodes(bytes.sublist(8, 12))
        : '';
    return brand == 'qt  ' ? '.mov' : '.mp4';
  }

  static String _name(CloudFile file) {
    String safe(String? value) =>
        (value ?? '').replaceAll(RegExp(r'[^A-Za-z0-9]'), '');
    return '${safe(file.id)}-${safe(file.etag)}';
  }
}
