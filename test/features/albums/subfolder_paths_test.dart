import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/albums/subfolder_paths.dart';
import 'package:ncloud/models.dart';

CloudFile file(
  String name, {
  String type = 'image/jpeg',
  List<String> parent = const ['Photos'],
}) => CloudFile(
  path: [...parent, name],
  name: name,
  isDirectory: false,
  contentType: type,
);

void main() {
  test('sub-folder chips list each child that holds media, once', () {
    final items = [
      file('a.jpg', parent: ['Photos', 'Trip', 'Day1']),
      file('b.jpg', parent: ['Photos', 'Trip', 'Day1']),
      file('c.jpg', parent: ['Photos', 'Trip', 'Day2']),
      file('d.jpg', parent: ['Photos', 'Trip']),
      file('notes.txt', type: 'text/plain', parent: ['Photos', 'Trip', 'Docs']),
    ];
    expect(subfolderPaths(items, ['Photos', 'Trip']), [
      ['Photos', 'Trip', 'Day1'],
      ['Photos', 'Trip', 'Day2'],
    ]);
    expect(subfolderPaths(items, ['Photos', 'Trip', 'Day1']), isEmpty);
  });
}
