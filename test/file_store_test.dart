import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/file_store.dart';
import 'package:ncloud/models.dart';

CloudFile file(List<String> path, {bool directory = false, String? etag}) =>
    CloudFile(
      path: path,
      name: path.last,
      isDirectory: directory,
      contentType: directory ? 'httpd/unix-directory' : 'image/jpeg',
      etag: etag,
    );

void main() {
  test(
    'invalid cached folder scope and duplicate members force revalidation',
    () {
      final store = FileStore();
      final direct = file(['Photos', 'Trip'], directory: true);
      for (final children in [
        [direct, direct],
        [
          direct,
          file(['Photos', 'Trip', 'Trip'], directory: true),
        ],
        [
          file(['Other', 'Trip'], directory: true),
        ],
      ]) {
        store.putFolder(['Photos'], children);
        expect(store.folder(['Photos']), isNull);
        expect(store.folder(['Photos'], fresh: false), isNull);
      }
    },
  );

  test(
    'folder indexes resolve shared entries and patches reach every view',
    () {
      final store = FileStore();
      final a = file(['Photos', 'a.jpg']);
      final b = file(['Photos', 'b.jpg']);
      store.putFolder(['Photos'], [a, b]);
      expect(store.folder(['Photos'])!.map((f) => f.name), ['a.jpg', 'b.jpg']);
      store.update(a.key, (f) => f.withFavorite(true));
      expect(store.folder(['Photos'])!.first.favorite, isTrue);
      expect(store.resolve([a.key]).single.favorite, isTrue);
      store.markStale();
      expect(store.folder(['Photos']), isNull);
      expect(store.folder(['Photos'], fresh: false), hasLength(2));
    },
  );

  test('move, copy and delete patch files and drop affected listings', () {
    final store = FileStore();
    store.putFolder([], [
      file(['Photos'], directory: true),
    ]);
    store.putFolder(
      ['Photos'],
      [
        file(['Photos', 'Trip'], directory: true),
      ],
    );
    store.putFolder(
      ['Photos', 'Trip'],
      [
        file(['Photos', 'Trip', 'a.jpg']),
      ],
    );
    store.moveTree(['Photos', 'Trip'], ['Archive', 'Trip']);
    expect(store[pathKey(['Photos', 'Trip', 'a.jpg'])], isNull);
    expect(store[pathKey(['Archive', 'Trip', 'a.jpg'])], isNotNull);
    expect(store.folder(['Photos']), isEmpty);
    expect(store.folder([]), isNull);
    store.moveTree(['Archive', 'Trip'], ['Copy'], copy: true);
    expect(store[pathKey(['Archive', 'Trip', 'a.jpg'])], isNotNull);
    expect(store[pathKey(['Copy', 'a.jpg'])], isNotNull);
    store.removeTree(['Copy']);
    expect(store[pathKey(['Copy', 'a.jpg'])], isNull);
    store.invalidateFolder(['Photos', 'Other']);
    expect(store.folder(['Photos']), isNull);
  });

  test('round trips through JSON and keeps unchanged etag listings fresh', () {
    final store = FileStore();
    store.putFolder(
      ['Photos'],
      [
        file(['Photos', 'a.jpg']),
      ],
      etag: 'v1',
    );
    final restored = FileStore()
      ..restore(jsonDecode(jsonEncode(store.toJson())) as Map<String, dynamic>);
    expect(restored.folder(['Photos'])!.single.name, 'a.jpg');
    expect(restored.length, 1);
    final other = FileStore();
    other.putFolder(
      ['Photos'],
      [
        file(['Photos', 'a.jpg']),
      ],
      etag: 'v1',
    );
    other.markStale();
    other.putAll([
      file(['Photos'], directory: true, etag: 'v1'),
    ]);
    expect(other.folder(['Photos']), isNull, reason: 'stale beats etag');
  });
}
