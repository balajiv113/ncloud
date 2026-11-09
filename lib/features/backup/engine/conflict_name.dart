import 'dart:convert';

import '../model/backup_id.dart';

/// A name for an upload whose destination already exists, so the existing file
/// is never overwritten: `photo.jpg` becomes `photo (ncloud device 1a2b…).jpg`.
///
/// The stem is shortened, counting UTF-8 bytes, to leave room for the suffix on
/// common filesystems. An extension too long to keep is rejected rather than
/// cut. [direction] says which side the new copy came from.
List<String> conflictName(
  List<String> path,
  String direction, {
  String Function()? suffix,
}) {
  final name = path.last;
  final dot = name.lastIndexOf('.');
  final split = dot > 0 ? dot : name.length;
  var stem = name.substring(0, split);
  final extension = name.substring(split);
  if (utf8.encode(extension).length > 32) {
    throw const FormatException(
      'File extension is too long to preserve safely.',
    );
  }
  while (utf8.encode(stem).length > 140) {
    stem = String.fromCharCodes(stem.runes.take(stem.runes.length - 1));
  }
  final tag = (suffix ?? () => newBackupId().substring(0, 12))();
  return [
    ...path.take(path.length - 1),
    '$stem (ncloud $direction $tag)$extension',
  ];
}
