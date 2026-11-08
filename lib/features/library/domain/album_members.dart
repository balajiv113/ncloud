import '../../../core/cloud/cloud_backend.dart';
import '../../../models.dart';

/// Reconciles sparse album metadata with already known account files.
List<CloudFile> reconcileAlbumMembers(
  List<CloudAlbumMember> members,
  Iterable<CloudFile> library,
) {
  final known = {
    for (final file in library)
      if (file.id != null) file.id!: file,
  };
  final result = <CloudFile>[];
  for (final member in members) {
    if (member.reference.isEmpty) {
      throw const FormatException('Album member has no reference.');
    }
    final existing = known[member.id];
    final type = member.contentType ?? existing?.contentType ?? '';
    if (!type.startsWith('image/') && !type.startsWith('video/')) continue;
    final name = member.originalName ?? existing?.name ?? member.displayName;
    result.add(
      CloudFile(
        path: existing == null
            ? ['Albums', ...member.reference]
            : name != existing.name && !existing.readOnly
            ? [CloudFile.pendingRoot, member.id!]
            : existing.path,
        name: name == null || name.isEmpty ? member.reference.last : name,
        isDirectory: false,
        contentType: type,
        id: member.id,
        size: member.size ?? existing?.size ?? 0,
        modified: member.modified ?? existing?.modified,
        etag: member.revision ?? existing?.etag,
        albumReference: existing == null
            ? member.reference
            : existing.albumReference,
        favorite: member.favorite ?? existing?.favorite ?? false,
        taken: existing?.taken,
        captureDay: existing?.captureDay,
      ),
    );
  }
  return result;
}
