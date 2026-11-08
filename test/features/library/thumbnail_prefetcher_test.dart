import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/features/library/domain/preview_batcher.dart';
import 'package:ncloud/features/library/domain/thumbnail_prefetcher.dart';
import 'package:ncloud/features/library/domain/thumbnail_repository.dart';
import 'package:ncloud/models.dart';

import '../../nextcloud_client_test.dart' show account;

class _Backend implements CloudBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

int _today() => DateTime.now().toUtc().millisecondsSinceEpoch ~/ 86400000;

CloudFile photo(String id, {int? daysAgo = 1, String type = 'image/jpeg'}) =>
    CloudFile(
      path: ['Photos', '$id.jpg'],
      name: '$id.jpg',
      isDirectory: false,
      contentType: type,
      id: id,
      captureDay: daysAgo == null ? null : _today() - daysAgo,
      etag: 'e$id',
    );

Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 60));

void main() {
  late List<String> fetched;
  late int failures;
  late bool active;
  late bool idle;
  Object? failWith;

  ThumbnailPrefetcher build({int batchSize = 2, int limit = 100}) {
    final thumbnails = ThumbnailRepository(
      client: _Backend(),
      cache: null,
      account: () => account,
      active: () => true,
      batchAvailable: () => false,
      offlineOriginal: (_) async => null,
    );
    return ThumbnailPrefetcher(
      thumbnails: thumbnails,
      account: () => account,
      enabled: () => true,
      active: () => active,
      idle: () => idle,
      fetch: (file) async {
        fetched.add(file.id!);
        if (failWith != null) throw failWith!;
      },
      onFailure: () => failures++,
      limit: limit,
      recentDays: 30,
      batchSize: batchSize,
      delay: const Duration(milliseconds: 1),
    );
  }

  setUp(() {
    fetched = [];
    failures = 0;
    active = true;
    idle = true;
    failWith = null;
  });

  test('only recent, dated media is fetched, once each', () async {
    final prefetcher = build(batchSize: 10);
    prefetcher
      ..queue([
        photo('a'),
        photo('old', daysAgo: 400),
        photo('undated', daysAgo: null),
        photo('doc', type: 'text/plain'),
        photo('a'),
      ])
      ..queue([photo('b')]);
    await settle();
    expect(fetched, ['a', 'b']);
    prefetcher.queue([photo('a')]);
    await settle();
    expect(fetched, ['a', 'b']);
  });

  test('photos are fetched in batches, one after another', () async {
    final prefetcher = build();
    prefetcher.queue([
      for (final id in ['1', '2', '3', '4', '5']) photo(id),
    ]);
    await settle();
    expect(fetched, ['1', '2', '3', '4', '5']);
  });

  test('it waits while the library is busy and continues when idle', () async {
    final prefetcher = build();
    idle = false;
    prefetcher.queue([photo('a')]);
    await settle();
    expect(fetched, isEmpty);
    idle = true;
    await settle();
    expect(fetched, ['a']);
  });

  test('it does nothing while inactive and resumes on schedule', () async {
    final prefetcher = build();
    active = false;
    prefetcher.queue([photo('a')]);
    await settle();
    expect(fetched, isEmpty);
    active = true;
    prefetcher.schedule();
    await settle();
    expect(fetched, ['a']);
  });

  test('pausing stops a batch from starting but keeps the queue', () async {
    final prefetcher = build();
    prefetcher.queue([photo('a')]);
    prefetcher.pause();
    await settle();
    expect(fetched, isEmpty);
    prefetcher.schedule();
    await settle();
    expect(fetched, ['a']);
  });

  test('failures are reported but cancelled previews are not', () async {
    final prefetcher = build();
    failWith = const CloudException('Preview timed out.');
    prefetcher.queue([photo('a')]);
    await settle();
    expect(failures, 1);
    failWith = const PreviewCancelled();
    prefetcher.queue([photo('b')]);
    await settle();
    expect(fetched, ['a', 'b']);
    expect(failures, 1);
  });

  test('clearing forgets queued photos so they can be queued again', () async {
    final prefetcher = build();
    idle = false;
    prefetcher.queue([photo('a')]);
    prefetcher.clear();
    idle = true;
    await settle();
    expect(fetched, isEmpty);
    prefetcher.queue([photo('a')]);
    await settle();
    expect(fetched, ['a']);
  });

  test('it remembers no more photos than its limit', () async {
    final prefetcher = build(limit: 2);
    prefetcher.queue([photo('a'), photo('b'), photo('c')]);
    await settle();
    expect(fetched, ['a', 'b']);
  });
}
