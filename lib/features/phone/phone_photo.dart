import '../backup/model/backup_state.dart';
import '../backup/platform/device_library.dart';

/// One photo or video on the phone.
class PhonePhoto {
  const PhonePhoto({
    required this.id,
    required this.name,
    required this.size,
    required this.taken,
    required this.isVideo,
    required this.album,
  });

  factory PhonePhoto.fromLibrary(LibraryItem item) => PhonePhoto(
    id: item.id,
    name: item.name,
    size: item.size,
    taken: DateTime.fromMillisecondsSinceEpoch(item.taken),
    isVideo: item.contentType.startsWith('video/'),
    album: albumOf(item.folder),
  );

  /// The name of the album a phone folder stands for: `DCIM/Camera` is `Camera`.
  /// Photos in no folder at all are in `Phone`.
  static String albumOf(String folder) => folder
      .split('/')
      .lastWhere((part) => part.isNotEmpty, orElse: () => 'Phone');

  /// The phone's own id for it.
  final String id;
  final String name;

  /// Its size in bytes, or a negative number when the phone does not say.
  final int size;
  final DateTime taken;
  final bool isVideo;

  /// The album the phone keeps it in, such as `Camera` or `Screenshots`.
  final String album;

  /// What a backup that has no phone ids recognises it by, or null when the size
  /// is not known and a name alone would match the wrong photo.
  String? get nameAndSize => size > 0 ? '$name|$size' : null;
}

/// A photo on the phone and where the backup stands with it.
class PhoneEntry {
  const PhoneEntry(this.photo, this.state);

  final PhonePhoto photo;
  final BackupState state;
}
