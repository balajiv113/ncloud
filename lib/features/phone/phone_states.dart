import '../backup/engine/file_mark.dart';
import '../backup/model/backup_state.dart';
import 'phone_photo.dart';

/// Looks up where the backup stands with each photo on the phone, from what
/// every backup knows about the files it covers. A photo that no backup knows
/// is left out.
class PhoneStates {
  PhoneStates(Iterable<FileMark> marks) {
    for (final mark in marks) {
      _keep(_byId, mark.id, mark.state);
      _keep(
        _byNameAndSize,
        mark.size > 0 ? '${mark.name}|${mark.size}' : null,
        mark.state,
      );
    }
  }

  final Map<String, BackupState> _byId = {};
  final Map<String, BackupState> _byNameAndSize = {};

  static void _keep(
    Map<String, BackupState> into,
    String? key,
    BackupState state,
  ) {
    if (key == null) return;
    into.update(
      key,
      (old) => old.index <= state.index ? old : state,
      ifAbsent: () => state,
    );
  }

  BackupState of(PhonePhoto photo) =>
      _byId[photo.id] ??
      _byNameAndSize[photo.nameAndSize] ??
      BackupState.leftOut;
}
