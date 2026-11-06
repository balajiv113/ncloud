import 'models.dart';

String pathKey(List<String> path) => path.map(Uri.encodeComponent).join('/');

class _FolderIndex {
  _FolderIndex(this.children, this.updated, this.etag);
  List<String> children;
  final DateTime updated;
  final String? etag;
}

/// A bounded mutation journal snapshot, acknowledged only after its transaction
/// commits. Later mutations remain pending while that write is in flight.
class FileStoreChanges {
  FileStoreChanges({
    required this.revision,
    required this.replace,
    required this.files,
    required this.observedAt,
    required this.folders,
    required this.staleBefore,
  });

  final int revision;
  final bool replace;
  final Map<String, CloudFile?> files;
  final Map<String, DateTime> observedAt;
  final Map<String, Map<String, dynamic>?> folders;
  final DateTime staleBefore;
}

/// Single normalized cache of every file the app has seen. Timeline, albums,
/// shared folders and Drive all reference entries here by key, so a file
/// fetched by one view is reused by the others and a mutation patches every
/// view at once instead of forcing reloads.
class FileStore {
  static const maxFiles = 40000;
  static const maxFolders = 4000;
  static const maxFolderMembers = 80000;
  static const folderFreshness = Duration(minutes: 5);

  final Map<String, CloudFile> _files = {};
  final Map<String, _FolderIndex> _folders = {};
  final Map<String, DateTime> _seen = {};
  final Map<String, ({int revision, CloudFile? file, DateTime? observed})>
  _changedFiles = {};
  final Map<String, int> _changedFolders = {};
  int? _clearedAt;
  int _folderMembers = 0;

  void _changedFile(String key) {
    _changedFiles[key] = (
      revision: revision + 1,
      file: _files[key],
      observed: _seen[key],
    );
    if (_changedFiles.length > maxFiles * 2) {
      _changedFiles.clear();
      _clearedAt = revision + 1;
    }
  }

  void _changedFolder(String key) {
    _changedFolders[key] = revision + 1;
    if (_changedFolders.length > maxFolders * 2) {
      _changedFolders.clear();
      _clearedAt = revision + 1;
    }
  }

  void _removeFolder(String key) {
    final old = _folders.remove(key);
    if (old != null) {
      _folderMembers -= old.children.length;
      _changedFolder(key);
    }
  }

  void _boundFolders() {
    while (_folders.length > maxFolders || _folderMembers > maxFolderMembers) {
      _removeFolder(_folders.keys.first);
    }
  }

  /// Views cached before this moment must revalidate with the server.
  DateTime staleBefore = DateTime.fromMillisecondsSinceEpoch(0);

  /// Increments on every change so resolved views can be memoized.
  int revision = 0;

  int get length => _files.length;
  CloudFile? operator [](String key) => _files[key];

  void putAll(Iterable<CloudFile> files) {
    final now = DateTime.now();
    for (final file in files) {
      _files.remove(file.key);
      _files[file.key] = file;
      _seen[file.key] = now;
      _changedFile(file.key);
    }
    while (_files.length > maxFiles) {
      final key = _files.keys.first;
      _files.remove(key);
      _seen.remove(key);
      // RAM eviction is not a server deletion. Pending upserts retain the
      // immutable row until committed, and the disk catalogue keeps older rows.
    }
    revision++;
  }

  List<CloudFile> resolve(Iterable<String> keys) => [
    for (final key in keys) ?_files[key],
  ];

  /// Records the direct children of [path], as returned by the server.
  void putFolder(List<String> path, List<CloudFile> children, {String? etag}) {
    putAll(children);
    final key = pathKey(path);
    _removeFolder(key);
    final bounded = children.take(maxFiles);
    _folders[key] = _FolderIndex(
      [for (final child in bounded) child.key],
      DateTime.now(),
      etag,
    );
    _folderMembers += _folders[key]!.children.length;
    _changedFolder(key);
    _boundFolders();
    revision++;
  }

  /// Direct children of [path] when known. With [fresh] the index is only
  /// returned if recent or if the folder's etag, observed after indexing,
  /// shows nothing changed below it.
  List<CloudFile>? folder(List<String> path, {bool fresh = true}) {
    final key = pathKey(path);
    final index = _folders[key];
    if (index == null) return null;
    if (fresh && !_folderFresh(key, index)) return null;
    final files = resolve(index.children);
    if (files.length != index.children.length ||
        files.map((f) => f.key).toSet().length != files.length ||
        files.any(
          (f) =>
              f.path.length != path.length + 1 || !pathStartsWith(f.path, path),
        )) {
      return null;
    }
    return files;
  }

  bool _folderFresh(String key, _FolderIndex index) {
    if (index.updated.isBefore(staleBefore)) return false;
    if (DateTime.now().difference(index.updated) < folderFreshness) return true;
    final self = _files[key];
    final seen = _seen[key];
    return index.etag != null &&
        self?.etag == index.etag &&
        seen != null &&
        seen.isAfter(index.updated);
  }

  /// Media or files already known below [path], used to show a view
  /// instantly while the server is asked for the authoritative list.
  List<CloudFile> where(bool Function(CloudFile file) test) =>
      _files.values.where(test).toList();

  void update(String key, CloudFile Function(CloudFile file) change) {
    final file = _files[key];
    if (file == null) return;
    _files[key] = change(file);
    _changedFile(key);
    revision++;
  }

  void removeKeys(Iterable<String> keys) {
    for (final key in keys) {
      _files.remove(key);
      _seen.remove(key);
      _changedFile(key);
    }
    revision++;
  }

  void removeTree(List<String> path) {
    final keys = _files.values
        .where((f) => pathStartsWith(f.path, path))
        .map((f) => f.key)
        .toList();
    for (final key in keys) {
      _files.remove(key);
      _seen.remove(key);
      _changedFile(key);
    }
    for (final key
        in _folders.keys.where((key) => _under(key, path)).toList()) {
      _removeFolder(key);
    }
    _detach(path);
    revision++;
  }

  void moveTree(List<String> from, List<String> to, {bool copy = false}) {
    final moved = [
      for (final file in _files.values.where(
        (f) => pathStartsWith(f.path, from),
      ))
        file.atPath([...to, ...file.path.skip(from.length)]),
    ];
    if (!copy) removeTree(from);
    putAll(moved);
    invalidateFolder(to.take(to.length - 1).toList());
  }

  /// Forgets the listing of [path] and every ancestor, whose contents or
  /// recursive etags changed.
  void invalidateFolder(List<String> path) {
    for (var depth = 0; depth <= path.length; depth++) {
      _removeFolder(pathKey(path.take(depth).toList()));
    }
    revision++;
  }

  void _detach(List<String> path) {
    if (path.isEmpty) return;
    final parentKey = pathKey(path.take(path.length - 1).toList());
    final parent = _folders[parentKey];
    if (parent != null && parent.children.remove(pathKey(path))) {
      _folderMembers--;
      _changedFolder(parentKey);
    }
    for (var depth = 0; depth < path.length - 1; depth++) {
      _removeFolder(pathKey(path.take(depth).toList()));
    }
  }

  static bool _under(String key, List<String> path) {
    final prefix = pathKey(path);
    return key == prefix || prefix.isEmpty || key.startsWith('$prefix/');
  }

  /// Marks every cached view as needing revalidation without discarding it.
  void markStale() {
    staleBefore = DateTime.now();
    revision++;
  }

  void clear() {
    _files.clear();
    _folders.clear();
    _seen.clear();
    _changedFiles.clear();
    _changedFolders.clear();
    _folderMembers = 0;
    _clearedAt = revision + 1;
    staleBefore = DateTime.fromMillisecondsSinceEpoch(0);
    revision++;
  }

  Map<String, dynamic> toJson() => {
    'files': [for (final file in _files.values) file.toJson()],
    'folders': {
      for (final entry in _folders.entries)
        entry.key: {
          'children': entry.value.children,
          'updated': entry.value.updated.toIso8601String(),
          'etag': entry.value.etag,
        },
    },
    'staleBefore': staleBefore.toIso8601String(),
  };

  FileStoreChanges persistenceChanges({bool full = false}) {
    final replace = full || _clearedAt != null;
    final folderKeys = replace ? _folders.keys : _changedFolders.keys;
    return FileStoreChanges(
      revision: revision,
      replace: replace,
      files: {
        for (final entry in _changedFiles.entries) entry.key: entry.value.file,
        if (replace)
          for (final entry in _files.entries) entry.key: entry.value,
      },
      observedAt: {
        for (final entry in _changedFiles.entries)
          entry.key: ?entry.value.observed,
        if (replace)
          for (final entry in _seen.entries) entry.key: entry.value,
      },
      folders: {for (final key in folderKeys) key: _folderJson(key)},
      staleBefore: staleBefore,
    );
  }

  Map<String, dynamic>? _folderJson(String key) {
    final folder = _folders[key];
    if (folder == null) return null;
    return {
      'children': List<String>.of(folder.children),
      'updated': folder.updated.toIso8601String(),
      'etag': folder.etag,
    };
  }

  void acknowledgePersistence(FileStoreChanges changes) {
    _changedFiles.removeWhere(
      (_, change) => change.revision <= changes.revision,
    );
    _changedFolders.removeWhere((_, at) => at <= changes.revision);
    if (_clearedAt != null && _clearedAt! <= changes.revision) {
      _clearedAt = null;
    }
  }

  void restore(Map<String, dynamic> json) {
    if (_files.isEmpty && _changedFiles.isEmpty && _changedFolders.isEmpty) {
      // Loading an existing catalogue after switching accounts is a new
      // persistence baseline, not a request to delete rows outside the RAM cap.
      _clearedAt = null;
    }
    for (final item
        in (json['files'] as List).reversed.take(maxFiles).toList().reversed) {
      final file = CloudFile.fromJson((item as Map).cast<String, dynamic>());
      if (_files.length >= maxFiles && !_files.containsKey(file.key)) continue;
      if (!_files.containsKey(file.key)) {
        _files[file.key] = file;
      }
    }
    for (final entry in (json['folders'] as Map).entries.take(maxFolders)) {
      final value = (entry.value as Map).cast<String, dynamic>();
      final key = entry.key as String;
      if (_folders.containsKey(key)) continue;
      final children = (value['children'] as List).cast<String>();
      if (_folderMembers + children.length > maxFolderMembers) continue;
      _folders[key] = _FolderIndex(
        List<String>.of(children),
        DateTime.parse(value['updated'] as String),
        value['etag'] as String?,
      );
      _folderMembers += children.length;
    }
    final stale = DateTime.tryParse(json['staleBefore'] as String? ?? '');
    if (stale != null && stale.isAfter(staleBefore)) staleBefore = stale;
    revision++;
  }
}
