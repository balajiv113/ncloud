import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../cloud/cloud_backend.dart';
import '../storage/local_cache.dart';
import '../../discovery_models.dart';
import '../../models.dart';
import 'preview_batcher.dart';
import 'preview_memory.dart';

/// What a tile paints: encoded preview bytes, or a saved original replayed
/// from the device.
typedef ThumbnailImage = ({Uint8List? bytes, File? original});

/// A tile's pending thumbnail. [release] tells the repository the tile no
/// longer needs it; it does nothing once the request has finished or if it
/// never queued a download.
class ThumbnailRequest {
  ThumbnailRequest._(this._repository, this._file, this._size);

  final ThumbnailRepository _repository;
  final CloudFile _file;
  final int _size;
  late final Future<ThumbnailImage> result;
  bool _held = false;

  void release() {
    if (!_held) return;
    _held = false;
    _repository.release(_file, size: _size);
  }
}

/// The one thumbnail cache shared by every screen: memory, then disk, then
/// the provider. File and face previews use the same stores and key scheme.
///
/// Photo thumbnails are keyed by account, file id and size and tagged with the
/// file revision. A cached thumbnail of an older revision is offered as
/// `stale` while its replacement loads.
class ThumbnailRepository {
  ThumbnailRepository({
    required this.client,
    required this.cache,
    required this.account,
    required this.active,
    required this.batchAvailable,
    required this.offlineOriginal,
  }) {
    _batcher = PreviewBatcher(
      client: client,
      session: account,
      active: () => active() && !_disposed,
      interested: (key) => (_interest[key] ?? 0) > 0,
    );
  }

  static const memoryBudget = 64 * 1024 * 1024;

  final CloudBackend client;
  final LocalCache? cache;
  final Account? Function() account;

  /// False while browsing is paused; queued batch requests are dropped.
  final bool Function() active;

  /// Whether the provider can serve several previews in one request.
  final bool Function() batchAvailable;

  /// A saved original for [file], replayed without any network request.
  final Future<File?> Function(CloudFile file) offlineOriginal;

  final PreviewMemory _memory = PreviewMemory(byteBudget: memoryBudget);
  late final PreviewBatcher _batcher;
  final Map<String, Future<Uint8List>> _loads = {};
  final Map<String, int> _interest = {};
  int _generation = 0;
  bool _disposed = false;

  String? key(CloudFile file, int size) {
    final session = account();
    if (session == null) return null;
    return '${session.storageKey}|${file.id ?? file.key}|$size';
  }

  /// The revision a thumbnail was rendered from, or null when the file only
  /// carries an id (such as an album cover). A file of unknown revision
  /// accepts any stored thumbnail, so it never replaces a versioned one that
  /// another screen stored for the same file.
  static String? versionOf(CloudFile file) {
    final etag = (file.etag ?? '').replaceAll('"', '');
    if (etag.isNotEmpty) return etag;
    final modified = file.modified;
    return modified == null
        ? null
        : '${modified.microsecondsSinceEpoch}|${file.size}';
  }

  static bool _matches(String? version, String stored) =>
      version == null || stored == version;

  /// Thumbnail already in memory, possibly from an older revision, so tiles
  /// can paint on their first frame without a loading state.
  Uint8List? cached(CloudFile file, {int size = 384}) =>
      _memory.get(key(file, size))?.bytes;

  /// Best bytes to paint immediately: this size, or for a larger request the
  /// grid thumbnail while the larger preview loads.
  Uint8List? paintable(CloudFile file, {int size = 384}) =>
      cached(file, size: size) ?? (size > 384 ? cached(file) : null);

  /// Whether [cached] matches the file's current revision.
  bool current(CloudFile file, {int size = 384}) {
    final k = key(file, size);
    final stored = _memory.peek(k);
    return stored != null && _matches(versionOf(file), stored.version);
  }

  /// Current thumbnail for [file]: memory, then disk, then the server.
  /// Callers must [release] if they stop waiting.
  Future<Uint8List> preview(
    CloudFile file, {
    bool retry = false,
    int size = 384,
    void Function(Uint8List bytes)? stale,
  }) {
    final session = account();
    final k = key(file, size);
    if (session == null || k == null) {
      return Future.error(const CloudException('Reconnect to load previews.'));
    }
    final version = versionOf(file);
    final generation = _generation;
    void checkCurrent() {
      if (_disposed ||
          !identical(account(), session) ||
          generation != _generation) {
        throw const PreviewCancelled();
      }
    }

    final memory = _memory.peek(k);
    if (!retry && memory != null && _matches(version, memory.version)) {
      _memory.get(k);
      return Future.value(memory.bytes);
    }
    final loadKey = '$k|${version ?? ''}';
    _interest[loadKey] = (_interest[loadKey] ?? 0) + 1;
    final existing = _loads[loadKey];
    if (existing != null && !retry) return existing;
    final disk = cache;
    Future<Uint8List> load() async {
      if (!retry && disk != null) {
        final stored = await disk.readThumbnail(k);
        checkCurrent();
        if (stored != null) {
          if (_matches(version, stored.version)) {
            _memory.put(k, stored.bytes, stored.version);
            return stored.bytes;
          }
          if (memory == null) stale?.call(stored.bytes);
        }
      }
      checkCurrent();
      final bytes = await _batcher.fetch(
        session,
        file,
        size,
        loadKey,
        batch: batchAvailable(),
      );
      checkCurrent();
      _memory.put(k, bytes, version ?? '');
      unawaited(disk?.writeThumbnail(k, bytes, version: version ?? ''));
      return bytes;
    }

    late final Future<Uint8List> pending;
    pending = load().whenComplete(() {
      if (identical(_loads[loadKey], pending)) {
        _loads.remove(loadKey);
        _interest.remove(loadKey);
      }
    });
    _loads[loadKey] = pending;
    return pending;
  }

  /// What a tile shows for [file]. A saved original is replayed before any
  /// request when nothing is cached, and also when the download fails and
  /// nothing is on screen yet. A tile that is already showing a thumbnail
  /// keeps it and sees the failure.
  ThumbnailRequest load(
    CloudFile file, {
    int size = 384,
    bool retry = false,
    void Function(Uint8List bytes)? stale,
  }) {
    final request = ThumbnailRequest._(this, file, size);
    request.result = () async {
      var showing = paintable(file, size: size) != null;
      if (!retry && file.isImage && cached(file, size: size) == null) {
        if (await offlineOriginal(file) case final original?) {
          return (bytes: null, original: original);
        }
      }
      request._held = true;
      try {
        final bytes = await preview(
          file,
          retry: retry,
          size: size,
          stale: (bytes) {
            showing = true;
            stale?.call(bytes);
          },
        );
        return (bytes: bytes, original: null);
      } on PreviewCancelled {
        rethrow;
      } on Object {
        if (!showing && file.isImage) {
          if (await offlineOriginal(file) case final original?) {
            return (bytes: null, original: original);
          }
        }
        rethrow;
      } finally {
        request._held = false;
      }
    }();
    return request;
  }

  /// Loads stored thumbnails into memory without any network request, so
  /// tiles paint on their first frame. An older revision is kept too; tiles
  /// show it until the current one arrives.
  Future<void> hydrate(Iterable<CloudFile> files, {int size = 384}) async {
    final disk = cache;
    final session = account();
    if (disk == null || session == null) return;
    final generation = _generation;
    bool stale() =>
        _disposed ||
        generation != _generation ||
        !identical(account(), session);
    final missing = [
      for (final file in files)
        if (!current(file, size: size)) file,
    ];
    for (var start = 0; start < missing.length && !stale(); start += 16) {
      await Future.wait([
        for (final file in missing.skip(start).take(16))
          () async {
            final k = key(file, size)!;
            final stored = await disk.readThumbnail(k);
            if (stored != null && !stale()) {
              _memory.put(k, stored.bytes, stored.version);
            }
          }(),
      ]);
    }
  }

  /// A tile no longer needs [file]'s thumbnail.
  void release(CloudFile file, {int size = 384}) {
    final k = key(file, size);
    if (k == null) return;
    final loadKey = '$k|${versionOf(file) ?? ''}';
    final interest = (_interest[loadKey] ?? 0) - 1;
    if (interest > 0) {
      _interest[loadKey] = interest;
    } else {
      _interest.remove(loadKey);
    }
  }

  String? _faceKey(RecognizedPerson person) {
    final session = account();
    return session == null
        ? null
        : 'face-v1|${session.storageKey}|${Uri.encodeComponent(person.id)}';
  }

  static String _faceVersion(RecognizedPerson person) =>
      '${Uri.encodeComponent(person.cover ?? '')}|${person.coverEtag ?? ''}';

  Uint8List? cachedFace(RecognizedPerson person) {
    final saved = _memory.peek(_faceKey(person));
    return saved?.version == _faceVersion(person) ? saved?.bytes : null;
  }

  /// Face from memory or disk, without any network request.
  Future<Uint8List?> restoreFace(RecognizedPerson person) async {
    final k = _faceKey(person);
    if (k == null) return null;
    if (cachedFace(person) case final saved?) return saved;
    final saved = await cache?.readThumbnail(k);
    if (saved == null ||
        saved.version != _faceVersion(person) ||
        k != _faceKey(person) ||
        _disposed) {
      return null;
    }
    _memory.put(k, saved.bytes, saved.version);
    return saved.bytes;
  }

  /// Face for the person's current cover: memory, then disk, then the server.
  Future<Uint8List> face(RecognizedPerson person) async {
    final session = account();
    final k = _faceKey(person);
    if (session == null || k == null) {
      throw const CloudException('Sign in to load people.');
    }
    if (await restoreFace(person) case final saved?) return saved;
    final version = _faceVersion(person);
    final loadKey = '$k|$version';
    if (_loads[loadKey] case final pending?) return pending;
    final generation = _generation;
    bool stale() =>
        generation != _generation ||
        !identical(account(), session) ||
        _disposed;
    final task = () async {
      final bytes = await client.personPreview(session, person);
      if (stale()) throw const PreviewCancelled();
      _memory.put(k, bytes, version);
      await cache?.writeThumbnail(k, bytes, version: version);
      if (stale()) throw const PreviewCancelled();
      return bytes;
    }();
    _loads[loadKey] = task;
    try {
      return await task;
    } finally {
      if (identical(_loads[loadKey], task)) _loads.remove(loadKey);
    }
  }

  /// Drops a face whose cover changed or whose person disappeared.
  Future<void> forgetFace(RecognizedPerson person) async {
    final k = _faceKey(person);
    if (k == null) return;
    _memory.remove(k);
    await cache?.removeThumbnail(k);
  }

  bool sameFace(RecognizedPerson a, RecognizedPerson b) =>
      _faceVersion(a) == _faceVersion(b);

  void pause() => _batcher.pause();

  /// Invalidates stored and in-flight results; late responses are dropped.
  void clear() {
    _generation++;
    _memory.clear();
    _loads.clear();
    _interest.clear();
    _batcher.clear();
  }

  void dispose() {
    _disposed = true;
    _batcher.dispose();
  }
}
