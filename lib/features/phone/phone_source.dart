import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/painting.dart';

import '../backup/platform/device_library.dart';
import '../backup/platform/folder_access.dart';
import 'phone_photo.dart';

/// The photos and videos on the phone.
abstract interface class PhoneSource {
  Future<LibraryPermission> permission();

  /// Asks the user, when the system allows it.
  Future<LibraryPermission> request();

  /// Every photo and video the app may read.
  Future<List<PhonePhoto>> photos();

  /// A small picture of one, as JPEG bytes, or null if there is none.
  Future<Uint8List?> thumbnail(String id, int size);

  /// The photo itself, to draw in full clarity, or null when the phone cannot
  /// give it. It is read where it is, not copied to a file.
  Future<ImageProvider?> image(String id);

  /// A video to play. It is the video where it is on the phone when the phone
  /// lets it be read there, and a temporary copy otherwise or when [copy] asks.
  Future<PhoneVideo> video(String id, {bool copy = false});

  /// Tells when the phone's library changes: a photo taken, deleted or edited.
  Stream<void> get changes;
}

/// A video ready to play. It is a file on the phone to play where it is, or a
/// temporary copy that [release] removes.
class PhoneVideo {
  PhoneVideo(this.file, {required this.temporary});

  final File file;
  final bool temporary;

  /// Done with the video: a copy is removed, the phone's own file is left alone.
  Future<void> release() async {
    if (!temporary) return;
    try {
      await file.delete();
    } on Object {
      // Nothing left to remove.
    }
  }
}

/// Reads the phone's library through the native side, which answers the same
/// way on Android and on iPhone.
class NativePhoneSource implements PhoneSource {
  NativePhoneSource(this._access) {
    NativeFolderAccess.channel.setMethodCallHandler((call) async {
      if (call.method == 'mediaChanged') _changes.add(null);
    });
  }

  final NativeFolderAccess _access;
  final StreamController<void> _changes = StreamController<void>.broadcast();

  @override
  Stream<void> get changes => _changes.stream;

  @override
  Future<LibraryPermission> permission() => _access.libraryPermission();

  @override
  Future<LibraryPermission> request() => _access.requestLibraryPermission();

  @override
  Future<Uint8List?> thumbnail(String id, int size) =>
      _access.mediaThumbnail(id, size);

  @override
  Future<ImageProvider?> image(String id) => _access.mediaImage(id);

  @override
  Future<PhoneVideo> video(String id, {bool copy = false}) async {
    final where = copy ? null : await _access.mediaPlayable(id);
    return where != null
        ? PhoneVideo(where, temporary: false)
        : PhoneVideo(await _access.mediaOriginal(id), temporary: true);
  }

  @override
  Future<List<PhonePhoto>> photos() async => [
    for (final item in await _access.libraryItems())
      PhonePhoto.fromLibrary(item),
  ];
}
