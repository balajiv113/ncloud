import '../model/backup_state.dart';

/// What the backup knows about one file on the phone: where it stands, and what
/// to recognise it by. The id is the phone's own and is the sure way to find the
/// photo again; the name and size are the fallback for a source that has none.
class FileMark {
  const FileMark({
    required this.id,
    required this.name,
    required this.size,
    required this.state,
  });

  final String? id;
  final String name;
  final int size;
  final BackupState state;
}
