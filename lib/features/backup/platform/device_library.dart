import 'folder_access.dart';

/// How much of the phone's photo library the app may read.
enum LibraryPermission {
  /// Everything.
  granted,

  /// Only photos the user picked (Android 14's "selected photos"). Backing up
  /// works but covers just those.
  partial,

  denied,
}

/// What the app needs to read a phone's whole photo and video library, beside
/// reading chosen folders.
abstract interface class LibraryAccess {
  Future<LibraryPermission> libraryPermission();

  /// Asks the user, when the system allows it.
  Future<LibraryPermission> requestLibraryPermission();

  /// Phone folders to leave out of the next listing, such as those another
  /// backup already covers.
  void skipFolders(List<List<String>> folders);
}

/// One photo or video in the phone's library, as the platform reports it.
class LibraryItem {
  const LibraryItem({
    required this.id,
    required this.name,
    required this.size,
    required this.modified,
    required this.contentType,
    required this.folder,
  });

  /// The platform's own id, such as `image:123`.
  final String id;
  final String name;
  final int size;

  /// Milliseconds since the epoch.
  final int modified;
  final String contentType;

  /// The folder it is in on the phone, such as `DCIM/Camera`. Empty at the top.
  final String folder;

  factory LibraryItem.fromMap(Map<dynamic, dynamic> value) => LibraryItem(
    id: value['id'] as String,
    name: value['name'] as String,
    size: (value['size'] as num).toInt(),
    modified: (value['modified'] as num).toInt(),
    contentType: value['contentType'] as String? ?? '',
    folder: value['folder'] as String? ?? '',
  );
}

/// A name that is safe on the server and on any file system: control
/// characters and slashes become underscores, and an empty name gets a stand-in.
String safeLibraryName(String name, {String fallback = '_'}) {
  final cleaned = name.replaceAll(RegExp(r'[/\\\x00-\x1f]'), '_').trim();
  if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') return fallback;
  return cleaned;
}

/// The phone's library as one flat list of album folders, named the way the
/// phone names them: photos in `DCIM/Camera` appear in `Camera`, those in
/// `Pictures/Screenshots` in `Screenshots`. There is no hierarchy to dig
/// through. Names are made stable, since a file or folder that changes name
/// between runs would look new.
class LibraryTree {
  /// [exclude] lists phone folders (as `DCIM/Camera` would be split) to leave
  /// out, such as those another backup already covers.
  LibraryTree(
    Iterable<LibraryItem> items, {
    Iterable<List<String>> exclude = const [],
  }) {
    final skipped = [for (final path in exclude) _normal(path)];
    final groups = <String, List<LibraryItem>>{};
    for (final item in items) {
      final folder = _normal(item.folder.split('/'));
      if (skipped.any((prefix) => _startsWith(folder, prefix))) continue;
      groups.putIfAbsent(folder.join('/'), () => []).add(item);
    }
    final used = <String>{};
    // In order, so the same phone always names its folders the same way.
    for (final path in groups.keys.toList()..sort()) {
      final name = _albumName(path.isEmpty ? const [] : path.split('/'), used);
      used.add(name);
      _files[name] = _named(groups[path]!);
    }
  }

  final Map<String, Map<String, LibraryItem>> _files = {};

  static List<String> _normal(Iterable<String> parts) => [
    for (final part in parts)
      if (part.isNotEmpty) part,
  ];

  static bool _startsWith(List<String> path, List<String> prefix) =>
      prefix.isNotEmpty &&
      path.length >= prefix.length &&
      [
        for (var i = 0; i < prefix.length; i++) path[i] == prefix[i],
      ].every((same) => same);

  /// The album folder for a phone folder: its own name, or when that is taken,
  /// with the folder above it, so `Pictures/Camera` beside `DCIM/Camera` becomes
  /// `Camera (Pictures)`.
  static String _albumName(List<String> path, Set<String> used) {
    if (path.isEmpty) return _free('Other', used);
    final own = safeLibraryName(path.last);
    if (!used.contains(own)) return own;
    final parent = path.length > 1
        ? safeLibraryName(path[path.length - 2])
        : 'storage';
    return _free('$own ($parent)', used);
  }

  static String _free(String name, Set<String> used) {
    var candidate = name;
    for (var n = 2; used.contains(candidate); n++) {
      candidate = '$name $n';
    }
    return candidate;
  }

  /// Gives each file in a folder a name that is its own. When two files share
  /// one, the file with the lowest id keeps it and the others add their id, so
  /// a name never changes when more files turn up later.
  static Map<String, LibraryItem> _named(List<LibraryItem> members) {
    members.sort((a, b) => _idNumber(a.id).compareTo(_idNumber(b.id)));
    final named = <String, LibraryItem>{};
    for (final item in members) {
      var name = safeLibraryName(item.name, fallback: 'file');
      if (named.containsKey(name)) {
        final dot = name.lastIndexOf('.');
        final suffix = '-${_idNumber(item.id)}';
        name = dot > 0
            ? '${name.substring(0, dot)}$suffix${name.substring(dot)}'
            : '$name$suffix';
      }
      named[name] = item;
    }
    return named;
  }

  static int _idNumber(String id) =>
      int.tryParse(id.substring(id.indexOf(':') + 1)) ?? 0;

  /// What is directly inside [path]: the album folders at the top, and a
  /// folder's photos and videos inside it.
  List<DeviceEntry> children(List<String> path) {
    if (path.isEmpty) {
      return [
        for (final name in _files.keys.toList()..sort())
          DeviceEntry(name, true, 0, 0),
      ];
    }
    if (path.length != 1) return const [];
    return [
      for (final MapEntry(key: name, value: item)
          in (_files[path.first] ?? const <String, LibraryItem>{}).entries)
        DeviceEntry(
          name,
          false,
          item.size,
          item.modified,
          contentType: item.contentType,
          id: item.id,
        ),
    ];
  }

  /// The library item at [path] (album folder, then file name), or null.
  LibraryItem? file(List<String> path) {
    if (path.length != 2) return null;
    return _files[path.first]?[path.last];
  }
}
