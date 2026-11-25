import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  /// A copy of one as it is, in a temporary file the caller removes.
  Future<File> original(String id);

  /// Tells when the phone's library changes: a photo taken, deleted or edited.
  Stream<void> get changes;
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
  Future<File> original(String id) => _access.mediaOriginal(id);

  @override
  Future<List<PhonePhoto>> photos() async => [
    for (final item in await _access.libraryItems())
      PhonePhoto.fromLibrary(item),
  ];
}
