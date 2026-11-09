import '../../models.dart';

/// The sub-folders of [directory] that hold [items]' media, in first-seen
/// order, so an album can be narrowed to one of them.
List<List<String>> subfolderPaths(
  Iterable<CloudFile> items,
  List<String> directory,
) {
  final children = <String, List<String>>{};
  for (final file in items) {
    if (file.isMedia && file.path.length > directory.length + 1) {
      final path = file.path.take(directory.length + 1).toList();
      children[path.last] = path;
    }
  }
  return children.values.toList();
}
