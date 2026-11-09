import 'dart:async';

import '../../core/cloud/cloud_backend.dart';
import '../../core/storage/local_cache.dart';
import '../../diagnostics.dart';
import '../../models.dart';

/// The albums of an account: Smart albums found by walking the photo source
/// folder, and albums stored on the server. It restores them from disk,
/// reuses them for fifteen minutes (or while the source folder's revision is
/// unchanged), and drops results that arrive after the account or a newer load
/// replaced them.
class AlbumCatalogue {
  AlbumCatalogue({
    required this.client,
    required this.cache,
    required this.account,
    required this.disposed,
    required this.onChanged,
    required this.photoRoot,
    required this.listFolder,
    required this.ensureIndex,
    required this.indexAvailable,
    required this.hydrate,
  });

  final CloudBackend client;
  final LocalCache? cache;
  final Account? Function() account;
  final bool Function() disposed;
  final void Function() onChanged;

  /// The folder albums are discovered under.
  final List<String> Function() photoRoot;

  /// Lists a folder through the shared folder cache.
  final Future<List<CloudFile>> Function(
    Account session,
    List<String> path, {
    bool force,
    bool Function()? isCurrent,
  })
  listFolder;

  /// Finds out whether the server has a day index before discovery uses it.
  final Future<void> Function(Account session) ensureIndex;
  final bool Function() indexAvailable;

  /// Brings stored cover thumbnails into memory.
  final void Function(Iterable<CloudFile> files) hydrate;

  final List<SmartAlbum> smart = [];
  List<CloudAlbum> server = [];
  bool discovering = false;
  int discovered = 0;
  String? error;
  String? serverError;

  /// The photo source chosen automatically when the account names none.
  List<String>? autoRoot;

  DateTime? _updated;
  String? _rootKey;
  String? _etag;
  int _version = 0;
  Future<void>? _task;
  Account? _session;

  bool _current(int generation, Account session) =>
      generation == _version && account() == session && !disposed();

  Future<void> load({bool refresh = false}) async {
    final session = account();
    if (session == null || disposed()) return;
    final pending = _task;
    if (!refresh && pending != null && _session == session) {
      return pending;
    }
    final generation = _version + 1;
    final task = () async {
      try {
        await _discover(session, refresh: refresh);
      } catch (e) {
        if (_current(generation, session)) {
          error = errorMessage(e);
          onChanged();
        }
      }
    }();
    _task = task;
    _session = session;
    try {
      await task;
    } finally {
      if (identical(_task, task)) _task = null;
    }
  }

  Future<void> _discover(Account session, {required bool refresh}) async {
    final generation = ++_version;
    if (session.photoRoot == null && autoRoot == null) {
      final sourceKey = 'album-source|${session.storageKey}';
      final saved = await cache?.readDocument(sourceKey);
      if (!_current(generation, session)) {
        return;
      }
      if (saved != null) {
        autoRoot = (saved['path'] as List).cast<String>();
      } else {
        final roots = await listFolder(
          session,
          [],
          isCurrent: () => generation == _version,
        );
        if (!_current(generation, session)) {
          return;
        }
        autoRoot = roots.any((f) => f.isDirectory && f.name == 'Photos')
            ? ['Photos']
            : [];
        await cache?.writeDocument(sourceKey, {'path': autoRoot});
      }
    }
    if (!_current(generation, session)) {
      return;
    }
    final root = [...photoRoot()];
    final rootKey = '${session.storageKey}|${root.join('/')}';
    if (!refresh &&
        _rootKey == rootKey &&
        _updated != null &&
        DateTime.now().difference(_updated!) < const Duration(minutes: 15)) {
      return;
    }
    final key = 'album-catalogue-v5|$rootKey';
    if (_rootKey != rootKey) {
      smart.clear();
      _updated = null;
      _etag = null;
      _rootKey = rootKey;
      server = [];
    }
    if (_updated == null) {
      final saved = await cache?.readDocument(key);
      if (!_current(generation, session)) return;
      if (saved != null) {
        smart.clear();
        smart.addAll(
          (saved['albums'] as List).map(
            (value) =>
                SmartAlbum.fromJson((value as Map).cast<String, dynamic>()),
          ),
        );
        server = [
          for (final value in saved['native'] as List)
            CloudAlbum.fromJson((value as Map).cast<String, dynamic>()),
        ];
        hydrate([
          ...smart.expand((album) => album.files.take(1)),
          ...server.map((album) => album.cover).nonNulls,
        ]);
        onChanged();
        final updated = DateTime.tryParse(saved['updated'] as String? ?? '');
        _updated = updated;
        _etag = saved['etag'] as String?;
        if (!refresh &&
            updated != null &&
            DateTime.now().difference(updated) < const Duration(minutes: 15)) {
          return;
        }
      }
    }
    final etag = cache == null
        ? null
        : (await client.listFolder(
            session,
            root,
            metadataOnly: true,
            optional: true,
          )).revision;
    if (!_current(generation, session)) {
      return;
    }
    if (!refresh && _updated != null && etag != null && etag == _etag) {
      // Album memberships can change independently of the files' etags.
      await _loadServerAlbums(session, generation);
      if (!_current(generation, session)) {
        return;
      }
      _updated = DateTime.now();
      await _save(key);
      return;
    }
    discovering = true;
    error = null;
    discovered = 0;
    final nativeLoad = _loadServerAlbums(session, generation);
    onChanged();
    try {
      await ensureIndex(session);
      if (!_current(generation, session)) return;
      final queue = <PhotoFolder>[PhotoFolder(root, [])];
      final found = <String, SmartAlbum>{};
      while (queue.isNotEmpty) {
        if (!_current(generation, session)) {
          return;
        }
        final folder = queue.removeAt(0);
        // The first folder with its own media on each branch is an album
        // (including everything below it); folders that only group other
        // folders are walked through. Loose media at the source root never
        // hides the albums inside it.
        final atRoot = folder.path.length == root.length;
        List<PhotoFolder> children;
        List<CloudFile> covers;
        if (indexAvailable()) {
          final result = await client.photoFolder(
            session,
            folder,
            includeChildrenWithMedia: atRoot,
          );
          covers = result.covers;
          children = result.children;
        } else {
          final contents = await listFolder(
            session,
            folder.path,
            force: refresh,
            isCurrent: () => generation == _version,
          );
          covers = contents.where((f) => f.isMedia).take(1).toList();
          children = covers.isNotEmpty && !atRoot
              ? []
              : contents
                    .where((f) => f.isDirectory)
                    .map((f) => PhotoFolder(f.path, []))
                    .toList();
        }
        if (!_current(generation, session)) {
          return;
        }
        if (covers.isNotEmpty) {
          final album = SmartAlbum(path: folder.path, files: covers);
          found[album.key] = album;
        }
        queue.addAll(children);
        discovered++;
      }
      smart
        ..clear()
        ..addAll(found.values);
      _updated = DateTime.now();
      _etag = etag;
      onChanged();
      await nativeLoad;
      if (!_current(generation, session)) {
        return;
      }
      await _save(key);
    } catch (e) {
      if (_current(generation, session)) {
        error = errorMessage(e);
      }
      rethrow;
    } finally {
      if (generation == _version) {
        discovering = false;
        onChanged();
      }
    }
  }

  Future<void> _save(String key) async {
    await cache?.writeDocument(key, {
      'updated': _updated!.toIso8601String(),
      'etag': _etag,
      'albums': smart.map((a) => a.toJson()).toList(),
      'native': [for (final album in server) album.toJson()],
    });
  }

  Future<void> _loadServerAlbums(Account session, int generation) async {
    serverError = null;
    try {
      final own = await client.albums(session);
      final shared = await client.albums(session, shared: true);
      if (_current(generation, session)) {
        server = [...own, ...shared];
      }
    } catch (e) {
      if (_current(generation, session)) {
        serverError = 'Could not load server albums. ${errorMessage(e)}';
      }
    } finally {
      if (_current(generation, session)) {
        onChanged();
      }
    }
  }

  /// Keeps what is shown but marks it stale, so the next load refreshes it and
  /// anything in flight is dropped.
  void invalidate() {
    if (_updated != null) _updated = DateTime.fromMillisecondsSinceEpoch(0);
    _version++;
    _task = null;
    _session = null;
    discovering = false;
  }

  /// Forgets everything, as after signing out.
  void reset() {
    smart.clear();
    server = [];
    _version++;
    _updated = null;
    _rootKey = null;
    _etag = null;
    _task = null;
    _session = null;
    discovering = false;
    discovered = 0;
    error = null;
    serverError = null;
    autoRoot = null;
  }
}
