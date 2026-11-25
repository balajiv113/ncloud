import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/app/browse_target.dart';
import 'package:ncloud/features/backup/engine/file_mark.dart';
import 'package:ncloud/features/backup/model/backup_state.dart';
import 'package:ncloud/features/backup/model/folder_pair.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/phone/not_backed_up_banner.dart';
import 'package:ncloud/features/phone/phone_badge.dart';
import 'package:ncloud/features/phone/phone_choice.dart';
import 'package:ncloud/features/phone/phone_library.dart';
import 'package:ncloud/features/phone/phone_photo.dart';
import 'package:ncloud/features/phone/phone_source.dart';
import 'package:ncloud/features/phone/phone_tile.dart';
import 'package:ncloud/features/phone/phone_timeline.dart';
import 'package:ncloud/features/phone/phone_viewer.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' show account;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=',
);

class _Source implements PhoneSource {
  _Source(this.photoList);
  final List<PhonePhoto> photoList;
  final asked = <String>[];

  @override
  Future<LibraryPermission> permission() async => LibraryPermission.granted;
  @override
  Future<LibraryPermission> request() async => LibraryPermission.granted;
  @override
  Future<List<PhonePhoto>> photos() async => photoList;
  @override
  Future<Uint8List?> thumbnail(String id, int size) async {
    asked.add('$id|$size');
    return _png;
  }

  @override
  Future<File> original(String id) async => throw UnimplementedError();
  @override
  Stream<void> get changes => const Stream.empty();
}

PhonePhoto photo(String id, int day) => PhonePhoto(
  id: id,
  name: '$id.jpg',
  size: 10,
  taken: DateTime(2025, 5, day, 12),
  isVideo: false,
);

FolderPair get pair => FolderPair(
  id: 'p',
  account: 'a|b',
  name: 'p',
  folder: const DeviceFolder('t', 'Camera', 'camera'),
  remote: const ['Backup'],
);

PhoneTimeline overlay(PhoneSource source, Map<String, BackupState> states) =>
    PhoneTimeline(
      choices: MemoryPhoneChoiceStore(),
      source: source,
      library: PhoneLibrary(
        source: source,
        pairs: () async => [pair],
        marks: (_) async => [
          for (final e in states.entries)
            FileMark(id: e.key, name: 'x', size: 1, state: e.value),
        ],
      ),
    );

void main() {
  testWidgets('a phone photo shows its thumbnail and says where it stands', (
    tester,
  ) async {
    final source = _Source([photo('a', 1)]);
    final phone = overlay(source, {'a': BackupState.failed});
    await phone.load();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 120,
          height: 120,
          child: PhoneTile(
            file: phone.files.single,
            thumbnails: phone.thumbnails!,
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.bySemanticsLabel('Could not be backed up'), findsOneWidget);
    expect(source.asked, ['a|384']);
  });

  testWidgets('each state has its own mark, and a left-out photo stands out', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [for (final state in BackupState.values) PhoneBadge(state)],
        ),
      ),
    );
    for (final state in BackupState.values) {
      expect(find.bySemanticsLabel(PhoneBadge.labelOf(state)), findsOneWidget);
    }
    expect({
      for (final s in BackupState.values) PhoneBadge.labelOf(s),
    }, hasLength(BackupState.values.length));
  });

  testWidgets(
    'the viewer swipes between phone photos and offers no cloud action',
    (tester) async {
      final source = _Source([photo('a', 2), photo('b', 1)]);
      final phone = overlay(source, {'a': BackupState.waiting});
      await phone.load();
      await tester.pumpWidget(
        MaterialApp(
          home: PhoneViewer(files: phone.files, initialIndex: 0, phone: phone),
        ),
      );
      await tester.pump();
      expect(find.text('a.jpg'), findsOneWidget);
      expect(find.textContaining('Waiting to back up'), findsWidgets);
      for (final cloudAction in [
        Icons.favorite_border,
        Icons.share,
        Icons.delete_outline,
        Icons.download,
      ]) {
        expect(find.byIcon(cloudAction), findsNothing);
      }
      // The header is only a strip across the top, so a swipe reaches the pages.
      expect(
        tester.getSize(find.byType(DecoratedBox).first).height,
        lessThan(120),
      );
      await tester.drag(find.byType(PageView), const Offset(-700, 0));
      await tester.pumpAndSettle();
      expect(find.text('b.jpg'), findsOneWidget);
      expect(find.textContaining('Not backed up'), findsWidgets);
    },
  );

  group('the controller', () {
    late AppController controller;
    setUp(() {
      controller = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((_) async => http.Response('', 404)),
        ),
        phoneTimeline: overlay(_Source([photo('a', 3), photo('b', 2)]), {
          'b': BackupState.backedUp,
        }),
      )..account = account;
      addTearDown(controller.dispose);
    });

    test(
      'lists the phone photos with the cloud ones in the Timeline only',
      () async {
        await controller.refreshPhone();
        expect(controller.timelineItems.map((f) => f.name), ['a.jpg']);
        expect(
          controller.items,
          isEmpty,
          reason: 'the cloud list is untouched',
        );
        controller.target = DriveTarget(const []);
        expect(controller.timelineItems, isEmpty);
        expect(controller.indexedDays, isEmpty);
      },
    );

    test('tells its listeners when the phone shows something new', () async {
      var notified = 0;
      controller.addListener(() => notified++);
      await controller.refreshPhone();
      expect(notified, 1);
      await controller.refreshPhone();
      expect(notified, 1, reason: 'nothing changed');
    });

    test('the Not backed up album shows the phone photos alone', () async {
      await controller.refreshPhone();
      await controller.openNotBackedUp();
      expect(controller.destination, Destination.albums);
      expect(controller.directory, ['Not backed up']);
      expect(controller.timelineItems.map((f) => f.name), ['a.jpg']);
      expect(controller.indexedDays, isEmpty);
      expect(
        controller.loading,
        isFalse,
        reason: 'nothing to load from the server',
      );
    });

    test('does not read the phone with nobody signed in', () async {
      controller.account = null;
      await controller.refreshPhone();
      expect(controller.timelineItems, isEmpty);
    });
  });

  test('the banner counts the photos in each state', () {
    expect(
      NotBackedUpBanner.summary({
        BackupState.waiting: 12,
        BackupState.leftOut: 3,
        BackupState.failed: 1,
      }),
      '12 waiting to back up · 1 could not be backed up · 3 left out',
    );
    expect(NotBackedUpBanner.summary({BackupState.leftOut: 2}), '2 left out');
    expect(NotBackedUpBanner.summary(const {}), '');
  });
}
