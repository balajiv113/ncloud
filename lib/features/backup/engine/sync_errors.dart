import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:sqflite/sqflite.dart';

import '../../../core/cloud/cloud_backend.dart';

/// Why a backup run failed, in words the user can act on, and the platform
/// error code when there was one. [phase] names what the run was doing, for
/// failures nothing more specific is known about.
({String message, String? code}) describeSyncError(
  Object error, {
  required String phase,
}) => (
  message: switch (error) {
    CloudException() => error.message,
    StateError() => error.message.toString(),
    FormatException() => error.message,
    MissingPluginException() =>
      'The native folder-sync service is unavailable. Install the latest ncloud build '
          'and fully restart the app. Reconnecting the folder will not fix this.',
    PlatformException() => _platform(error),
    DatabaseException() =>
      'Could not save sync progress (SQLite ${error.getResultCode() ?? 'unknown'}). '
          'Check device storage. Completed transfers may be copied again on retry.',
    FileSystemException() =>
      'Could not access a temporary transfer file. Check free device space.',
    SocketException() =>
      'The connection was interrupted. Retry when connected.',
    TimeoutException() => 'The transfer timed out. Retry when connected.',
    _ =>
      'Sync failed (${error.runtimeType}) during $phase. '
          'Existing files were not overwritten.',
  },
  code: error is PlatformException ? error.code : null,
);

String _platform(PlatformException error) => switch (error.code) {
  'media_permission' =>
    'Access to your photos and videos was removed. Allow it in your phone\'s '
        'settings, then back up again.',
  'photos_permission' ||
  'photos_changed' ||
  'photos_album' ||
  'photos_timeout' ||
  'photos_cancelled' ||
  'photos_unavailable' ||
  'photos_export' ||
  'backup_schedule' =>
    error.message ?? 'Photos album backup needs attention (${error.code}).',
  'folder_permission' =>
    'Access to the selected folder was denied. Reselect the source.',
  'folder_unavailable' =>
    'The selected folder or file is unavailable. Check its Files provider '
        'or connected device, then retry.',
  'folder_io' =>
    'The folder provider could not read or write the transfer. '
        'Check device space and whether the file is available offline.',
  'conditions_permission' =>
    'Android could not check Wi-Fi/charging conditions. '
        'Update ncloud and retry; folder permission is unchanged.',
  'background_permission' =>
    'Allow ncloud notifications in device Settings and retry.',
  'background_start' =>
    'Android could not start the upload service. Open ncloud and retry.',
  'scheduled_background' =>
    'Android could not show the scheduled backup notification. '
        'Allow Scheduled folder backups notifications and background activity in device Settings.',
  _ =>
    'The device folder operation failed (${error.code}). '
        'Existing files were not overwritten. Check the selected folder provider.',
};

/// Whether a failure with this platform [code] means the backup's source is no
/// longer reachable and the user should pick it again.
bool sourceNeedsReselect(String? code) => const {
  'folder_permission',
  'photos_permission',
  'photos_album',
  'media_permission',
}.contains(code);

/// Why saved backup settings could not be read, as a sentence for the screen.
/// [operation] is what was being attempted, such as "read saved folder
/// settings".
String describeLoadError(Object error, {required String operation}) {
  final detail = switch (error) {
    DatabaseException() =>
      'Database error ${error.getResultCode() ?? 'unknown'}. Saved folders and receipts have not been reset.',
    MissingPluginException() =>
      'The native backup service is unavailable. Fully close ncloud and install the latest build.',
    PlatformException() when error.code == 'backup_schedule' =>
      error.message ?? 'iOS could not register background backup.',
    PlatformException() => 'Device service error (${error.code}).',
    FormatException() => error.message,
    _ => 'Operation failed (${error.runtimeType}).',
  };
  return 'Could not $operation. $detail Retry loading folder settings.';
}
