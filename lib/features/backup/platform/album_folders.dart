import 'dart:convert';

import 'folder_access.dart';

/// The identity of the iPhone's whole library, as the phone names it.
const _cameraRollIdentity = 'photos:ncloud.camera-roll';

/// Token of the album that stands for the whole iPhone library.
final String cameraRollToken =
    'photos:${base64Encode(utf8.encode('ncloud.camera-roll'))}';

const _setPrefix = 'photoset:';

/// An iPhone album that gets a folder of its own on the server.
class AlbumChoice {
  const AlbumChoice(this.token, this.name);

  final String token;
  final String name;
}

/// The whole library, with some albums kept in folders of their own.
///
/// Each photo is stored once: under the first album in [albums] that holds
/// it, or in the top folder when it is in none of them. Photos moved into or
/// out of an album therefore move on the server instead of being uploaded
/// again.
DeviceFolder cameraRollWith(List<AlbumChoice> albums) => albums.isEmpty
    ? DeviceFolder(
        cameraRollToken,
        'Camera Roll',
        _cameraRollIdentity,
        kind: DeviceSourceKind.photoAlbum,
      )
    : DeviceFolder(
        '$_setPrefix${base64Url.encode(utf8.encode(jsonEncode([
          for (final a in albums) [a.token, a.name],
        ])))}',
        'Camera Roll',
        // The same identity as the plain library, so adding or removing
        // albums keeps this backup and what it has recorded.
        _cameraRollIdentity,
        kind: DeviceSourceKind.photoAlbum,
      );

/// The albums chosen in a whole-library backup, or null when [token] is not
/// one. An empty list means the library with no album folders.
List<AlbumChoice>? albumsOf(String token) {
  if (token == cameraRollToken) return const [];
  if (!token.startsWith(_setPrefix)) return null;
  final values =
      jsonDecode(
            utf8.decode(base64Url.decode(token.substring(_setPrefix.length))),
          )
          as List<dynamic>;
  return [
    for (final value in values)
      AlbumChoice((value as List<dynamic>)[0] as String, value[1] as String),
  ];
}

/// Whether [token] is the whole iPhone library, with or without album folders.
bool isCameraRoll(String token) => albumsOf(token) != null;

/// Where each photo goes, worked out from what the phone lists for each album
/// and for the whole library.
class AlbumFolderTree {
  AlbumFolderTree(
    List<AlbumChoice> albums,
    List<List<DeviceEntry>> inAlbum,
    List<DeviceEntry> library,
  ) {
    final claimed = <String>{};
    final used = <String>{};
    for (var i = 0; i < albums.length; i++) {
      final files = [
        for (final entry in inAlbum[i])
          if (!entry.directory && claimed.add(entry.name)) entry,
      ];
      if (files.isEmpty) continue;
      final folder = _unique(albums[i].name, used);
      _folders[folder] = files;
      _tokens[folder] = albums[i].token;
    }
    _top = [
      for (final entry in library)
        if (!entry.directory && !claimed.contains(entry.name)) entry,
    ];
  }

  final _folders = <String, List<DeviceEntry>>{};
  final _tokens = <String, String>{};
  late final List<DeviceEntry> _top;

  /// A folder name that is not used yet and cannot be a photo's name.
  static String _unique(String name, Set<String> used) {
    var candidate = name;
    for (var n = 2; !used.add(candidate); n++) {
      candidate = '$name ($n)';
    }
    return candidate;
  }

  /// What is directly in [path]: the album folders and loose photos at the
  /// top, the photos of one album below it.
  List<DeviceEntry> children(List<String> path) {
    if (path.isEmpty) {
      return [
        for (final name in _folders.keys) DeviceEntry(name, true, 0, 0),
        ..._top,
      ];
    }
    return path.length == 1 ? _folders[path.first] ?? const [] : const [];
  }

  /// The album to ask for the photo at [path] when exporting it: the album its
  /// folder stands for, or null for the whole library at the top.
  String? tokenFor(List<String> path) =>
      path.length == 2 ? _tokens[path.first] : null;
}
