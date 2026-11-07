import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/discovery_models.dart';
import 'package:ncloud/models.dart';

class _DelayedStore implements SessionStore {
  final readResult = Completer<String?>();

  @override
  Future<String?> read() => readResult.future;
  @override
  Future<void> write(String value) async {}
  @override
  Future<void> clear() async {}
}

class _Backend implements CloudBackend {
  final folderRequested = Completer<void>();
  final folderResult =
      Completer<({CloudFile? self, List<CloudFile> children})>();
  final dayRequested = Completer<void>();
  final dayResult = Completer<List<CloudFile>>();
  final nextDayRequested = Completer<void>();

  @override
  int get pageSize => 200;
  @override
  void close() {}

  @override
  Future<({CloudFile? self, List<CloudFile> children})> listFolder(
    Account account,
    List<String> path,
  ) {
    folderRequested.complete();
    return folderResult.future;
  }

  @override
  Future<List<TimelineDay>?> timelineDays(
    Account account, {
    List<String> path = const [],
    bool recursive = true,
    bool favorites = false,
    bool optional = false,
    bool existenceOnly = false,
    RecognizedPerson? person,
    PhotoMapBounds? mapBounds,
  }) async => const [
    TimelineDay(3, 1),
    TimelineDay(2, 201),
    TimelineDay(1, 201),
  ];

  @override
  Future<List<CloudFile>> timelineDayFiles(
    Account account,
    List<int> dayIds, {
    List<String> path = const [],
    bool favorites = false,
    bool recursive = true,
    bool resolvePaths = true,
    RecognizedPerson? person,
    PhotoMapBounds? mapBounds,
  }) async {
    if (dayIds.single == 2) {
      dayRequested.complete();
      return dayResult.future;
    }
    if (dayIds.single == 1) nextDayRequested.complete();
    return [
      for (var i = 0; i < (dayIds.single == 3 ? 1 : 201); i++)
        CloudFile(
          path: ['Photos', '${dayIds.single}-$i.jpg'],
          name: '${dayIds.single}-$i.jpg',
          isDirectory: false,
          contentType: 'image/jpeg',
          captureDay: dayIds.single,
        ),
    ];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  final account = Account(
    server: Uri.parse('https://cloud.example'),
    loginName: 'alice',
    appPassword: 'test-password',
    userId: 'alice',
    displayName: 'Alice',
  );

  test('disposed initialization cannot restore an account', () async {
    final store = _DelayedStore();
    final controller = AppController(store: store, client: _Backend());
    final pending = controller.initialize();
    controller.dispose();
    store.readResult.complete(account.encode());
    await pending;
    expect(controller.account, isNull);
  });

  test('cache clearing discards an in-flight folder listing', () async {
    final backend = _Backend();
    final controller = AppController(store: _DelayedStore(), client: backend)
      ..account = account;
    addTearDown(controller.dispose);
    final pending = controller.selectTab(1);
    await backend.folderRequested.future;
    await controller.clearCache();
    backend.folderResult.complete((
      self: null,
      children: [
        const CloudFile(
          path: ['private.jpg'],
          name: 'private.jpg',
          isDirectory: false,
        ),
      ],
    ));
    await pending;
    expect(controller.fileStore.length, 0);
    expect(controller.items, isEmpty);
    expect(controller.loading, isFalse);
    expect(controller.error, isNull);
  });

  test('Timeline retains its index and loaded photos during refresh', () async {
    final controller = AppController(store: _DelayedStore(), client: _Backend())
      ..account = account
      ..timelineIndexAvailable = true;
    addTearDown(controller.dispose);
    await controller.load();
    final days = controller.indexedDays;
    final items = controller.items;
    final refresh = controller.load();
    expect(controller.loading, isTrue);
    expect(controller.refreshing, isTrue);
    expect(controller.indexedDays, days);
    expect(controller.items, items);
    expect(controller.dayLoaded(3), isTrue);
    await refresh;
    expect(controller.error, isNull);
    expect(controller.indexedDays, hasLength(3));
    expect(controller.loading, isFalse);
  });

  test('a stale day failure does not strand a new destination queue', () async {
    final backend = _Backend();
    final controller = AppController(store: _DelayedStore(), client: backend)
      ..account = account
      ..timelineIndexAvailable = true;
    addTearDown(controller.dispose);
    await controller.load();
    controller.ensureDays([2]);
    await backend.dayRequested.future;
    await controller.selectTab(2);
    controller.ensureDays([1]);
    backend.dayResult.completeError(const CloudException('Old request failed'));
    await backend.nextDayRequested.future.timeout(const Duration(seconds: 5));
    // Let publication complete after the backend has received the new request.
    await Future<void>.delayed(Duration.zero);
    expect(controller.error, isNull);
    expect(controller.dayLoaded(1), isTrue);
    expect(controller.fetchingDays, isFalse);
  });
}
