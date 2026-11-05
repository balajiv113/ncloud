import 'models.dart';

String pathKey(List<String> path) => path.map(Uri.encodeComponent).join('/');

class _FolderIndex {
  _FolderIndex(this.children, this.updated, this.etag);
  List<String> children;
  final DateTime updated;
  final String? etag;
}

/// Single normalized cache of every file the app has seen. Timeline, albums,
/// shared folders and Drive all reference entries here by key, so a file
/// fetched by one view is reused by the others and a mutation patches every
/// view at once instead of forcing reloads.
class FileStore {
  static const maxFiles = 40000;
  static const folderFreshness = Duration(minutes: 5);

  final Map<String, CloudFile> _files = {};
  final Map<String, _FolderIndex> _folders = {};
  final Map<String, DateTime> _seen = {};

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
    }
    while (_files.length > maxFiles) {
      final key = _files.keys.first;
      _files.remove(key);
      _seen.remove(key);
    }
    revision++;
  }

  List<CloudFile> resolve(Iterable<String> keys) => [
    for (final key in keys)
      if (_files[key] case final file?) file,
  ];

  /// Records the direct children of [path], as returned by the server.
  void putFolder(List<String> path, List<CloudFile> children, {String? etag}) {
    putAll(children);
    _folders[pathKey(path)] = _FolderIndex(
      [for (final child in children) child.key],
      DateTime.now(),
      etag,
    );
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
    return files.length == index.children.length ? files : null;
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
    }
    _folders.removeWhere((key, _) => _under(key, path));
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
      _folders.remove(pathKey(path.take(depth).toList()));
    }
    revision++;
  }

  void _detach(List<String> path) {
    if (path.isEmpty) return;
    final parent = _folders[pathKey(path.take(path.length - 1).toList())];
    parent?.children.remove(pathKey(path));
    for (var depth = 0; depth < path.length - 1; depth++) {
      _folders.remove(pathKey(path.take(depth).toList()));
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

  void restore(Map<String, dynamic> json) {
    for (final item in json['files'] as List) {
      final file = CloudFile.fromJson((item as Map).cast<String, dynamic>());
      _files.putIfAbsent(file.key, () => file);
    }
    for (final entry in (json['folders'] as Map).entries) {
      final value = (entry.value as Map).cast<String, dynamic>();
      _folders.putIfAbsent(
        entry.key as String,
        () => _FolderIndex(
          (value['children'] as List).cast<String>(),
          DateTime.parse(value['updated'] as String),
          value['etag'] as String?,
        ),
      );
    }
    final stale = DateTime.tryParse(json['staleBefore'] as String? ?? '');
    if (stale != null && stale.isAfter(staleBefore)) staleBefore = stale;
    revision++;
  }
}
