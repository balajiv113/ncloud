import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/core/storage/local_cache.dart';
import 'package:ncloud/features/library/cached_resource.dart';
import 'package:ncloud/models.dart';

import 'nextcloud_client_test.dart' show account;

void main() {
  late Directory dir;
  late LocalCache cache;
  Account? current;
  var fetches = 0;
  var changes = 0;
  var damaged = 0;
  var disposed = false;
  Completer<List<int>?>? gate;
  List<int>? answer;
  final restored = <List<int>>[];
  final replaced = <(List<int>, List<int>)>[];

  CachedResource<List<int>> resource({
    Duration freshFor = const Duration(minutes: 5),
    bool trustStoredTime = false,
  }) => CachedResource<List<int>>(
    empty: const [],
    freshFor: freshFor,
    account: () => current,
    disposed: () => disposed,
    cache: cache,
    key: (_) => 'numbers',
    fetch: (_, _) {
      fetches++;
      return gate?.future ?? Future.value(answer);
    },
    encode: (value, updated) => {
      'numbers': value,
      'updated': updated.toIso8601String(),
    },
    decode: (document) {
      final rows = document['numbers'];
      if (rows is! List) throw const FormatException('damaged');
      return (
        value: [...rows.cast<int>()],
        updated: trustStoredTime
            ? DateTime.parse(document['updated'] as String)
            : null,
      );
    },
    onChanged: () => changes++,
    onRestored: restored.add,
    replace: (old, next) async => replaced.add((old, next)),
    onDamaged: () => damaged++,
  );

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('ncloud-resource-');
    cache = LocalCache(() async => dir);
    current = account;
    fetches = changes = damaged = 0;
    disposed = false;
    gate = null;
    answer = [1, 2];
    restored.clear();
    replaced.clear();
  });

  tearDown(() async {
    await cache.close();
    await dir.delete(recursive: true);
  });

  test('a fresh value is reused and a refresh bypasses freshness', () async {
    final r = resource();
    await r.load();
    expect(r.value, [1, 2]);
    expect(r.available, isTrue);
    await r.load();
    expect(fetches, 1);
    answer = [3];
    await r.load(refresh: true);
    expect(fetches, 2);
    expect(r.value, [3]);
  });

  test('concurrent loads share one request', () async {
    final r = resource();
    gate = Completer();
    final first = r.load();
    final second = r.load();
    gate!.complete([7]);
    await Future.wait([first, second]);
    expect(fetches, 1);
    expect(r.value, [7]);
    expect(r.loading, isFalse);
  });

  test('stored values show first and are replaced by the server', () async {
    await cache.writeDocument('numbers', {
      'numbers': [9],
      'updated': DateTime.now().toIso8601String(),
    });
    final r = resource();
    gate = Completer();
    final loading = r.load();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(r.value, [9]);
    expect(restored, [
      [9],
    ]);
    gate!.complete([4]);
    await loading;
    expect(r.value, [4]);
    expect(replaced.single.$1, [9]);
    expect(replaced.single.$2, [4]);
  });

  test('a stored timestamp can make the stored value fresh', () async {
    await cache.writeDocument('numbers', {
      'numbers': [9],
      'updated': DateTime.now().toIso8601String(),
    });
    final r = resource(trustStoredTime: true);
    await r.load();
    expect(r.value, [9]);
    expect(fetches, 0);
  });

  test('a damaged document is reported and the server is asked', () async {
    await cache.writeDocument('numbers', {'numbers': 'damaged'});
    final r = resource();
    await r.load();
    expect(damaged, 1);
    expect(r.value, [1, 2]);
    expect(r.error, isNull);
  });

  test('an unsupported provider is distinct from an empty answer', () async {
    answer = null;
    final r = resource();
    await r.load();
    expect(r.available, isFalse);
    expect(r.value, isEmpty);
    expect(r.error, isNull);
  });

  test('a failure keeps the previous value and records the error', () async {
    final r = resource();
    await r.load();
    gate = Completer();
    final loading = r.load(refresh: true);
    gate!.completeError(StateError('offline'));
    await loading;
    expect(r.value, [1, 2]);
    expect(r.error, isNotNull);
    expect(r.loading, isFalse);
  });

  test(
    'invalidate keeps the value, drops in-flight work and refetches',
    () async {
      final r = resource();
      await r.load();
      gate = Completer();
      final stale = r.load(refresh: true);
      r.invalidate();
      gate!.complete([5]);
      await stale;
      expect(r.value, [1, 2]);
      gate = null;
      answer = [6];
      await r.load();
      expect(r.value, [6]);
      expect(fetches, 3);
    },
  );

  test('a response for a signed-out account is discarded', () async {
    final r = resource();
    gate = Completer();
    final loading = r.load();
    current = null;
    gate!.complete([8]);
    await loading;
    expect(r.value, isEmpty);
    expect(r.available, isNull);
  });

  test('reset forgets the value and restores from disk next time', () async {
    final r = resource();
    await r.load();
    r.reset();
    expect(r.value, isEmpty);
    expect(r.available, isNull);
    gate = Completer();
    final loading = r.load();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(r.value, [1, 2]);
    gate!.complete([1, 2]);
    await loading;
  });

  test('nothing loads without an account or after disposal', () async {
    final r = resource();
    current = null;
    await r.load();
    current = account;
    disposed = true;
    await r.load();
    expect(fetches, 0);
  });
}
