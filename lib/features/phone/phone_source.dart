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
}

/// Reads the phone's library through the native side, which answers the same
/// way on Android and on iPhone.
class NativePhoneSource implements PhoneSource {
  NativePhoneSource(this._access);

  final NativeFolderAccess _access;

  @override
  Future<LibraryPermission> permission() => _access.libraryPermission();

  @override
  Future<LibraryPermission> request() => _access.requestLibraryPermission();

  @override
  Future<List<PhonePhoto>> photos() async => [
    for (final item in await _access.libraryItems())
      PhonePhoto.fromLibrary(item),
  ];
}
