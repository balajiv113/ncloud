import 'package:flutter/painting.dart';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/file_mark.dart';
import 'package:ncloud/features/backup/model/backup_state.dart';
import 'package:ncloud/features/backup/model/folder_pair.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/phone/phone_choice.dart';
import 'package:ncloud/features/phone/phone_library.dart';
import 'package:ncloud/features/phone/phone_photo.dart';
import 'package:ncloud/features/phone/phone_source.dart';
import 'package:ncloud/features/phone/phone_timeline.dart';
import 'package:ncloud/features/timeline/timeline_sections.dart';
import 'package:ncloud/models.dart';

PhonePhoto photo(
  String id,
  DateTime taken, {
  bool video = false,
  String album = 'Camera',
}) => PhonePhoto(
  id: id,
  name: '$id.jpg',
  size: 10,
  taken: taken,
  isVideo: video,
  album: album,
);

class _Source implements PhoneSource {
  _Source(this.all);
  List<PhonePhoto> all;
  LibraryPermission permissionIs = LibraryPermission.granted;

  @override
  Future<LibraryPermission> permission() async => permissionIs;
  @override
  Future<LibraryPermission> request() async => permissionIs;
  @override
  Future<List<PhonePhoto>> photos() async => all;
  @override
  Future<Uint8List?> thumbnail(String id, int size) async => null;
  @override
  Future<ImageProvider?> image(String id) async => null;
  @override
  Future<PhoneVideo> video(String id, {bool copy = false}) async =>
      throw UnimplementedError();
  @override
  Stream<void> get changes => const Stream.empty();
}

FolderPair get pair => FolderPair(
  id: 'p',
  account: 'a|b',
  name: 'p',
  folder: const DeviceFolder('t', 'Camera', 'camera'),
  remote: const ['Backup'],
);

PhoneTimeline timeline(PhoneSource source, Map<String, BackupState> states) =>
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

CloudFile cloud(String name, int day) => CloudFile(
  path: ['Photos', name],
  name: name,
  isDirectory: false,
  contentType: 'image/jpeg',
  captureDay: day,
);

int dayOf(int year, int month, int day) =>
    DateTime.utc(year, month, day).millisecondsSinceEpoch ~/ 86400000;

void main() {
  final may1 = DateTime(2025, 5, 1, 9);
  final may3 = DateTime(2025, 5, 3, 23, 30);

  test('shows only the photos the cloud does not have', () async {
    final phone = timeline(
      _Source([photo('done', may1), photo('wait', may1), photo('lost', may3)]),
      {'done': BackupState.backedUp, 'wait': BackupState.waiting},
    );
    expect(await phone.load(), isTrue);
    expect(phone.files.map((f) => f.onPhone!.id), ['lost', 'wait']);
    expect(phone.files.map((f) => f.onPhone!.state), [
      BackupState.leftOut,
      BackupState.waiting,
    ]);
  });

  test('groups the photos by the album the phone keeps them in', () async {
    final phone = timeline(
      _Source([
        photo('a', may1),
        photo('b', may3, album: 'Screenshots'),
        photo('c', may3, album: 'camera'),
        photo('done', may1, album: 'Screenshots'),
      ]),
      {'done': BackupState.backedUp},
    );
    await phone.load();
    // One album, named as its newest photo has it.
    expect(phone.albums.keys.toSet(), {'camera', 'Screenshots'});
    expect(phone.album('Camera').files.map((f) => f.onPhone!.id), ['c', 'a']);
    expect(
      phone.album('CAMERA').files,
      hasLength(2),
      reason: 'whatever the case',
    );
    expect(phone.album('Screenshots').files.single.onPhone!.id, 'b');
    expect(phone.album('Nothing').files, isEmpty);
    expect(phone.album('Screenshots').counts, {BackupState.leftOut: 1});
  });

  test('an album view lays in only its own photos and days', () async {
    final phone = timeline(
      _Source([photo('a', may1), photo('b', may3, album: 'Screenshots')]),
      {},
    );
    await phone.load();
    final cameraDays = phone.album('Camera').days([]);
    expect(cameraDays.map((d) => d.id), [dayOf(2025, 5, 1)]);
    final all = phone.all.days([]);
    expect(all.map((d) => d.id), [dayOf(2025, 5, 3), dayOf(2025, 5, 1)]);
    expect(phone.album('Camera').items([cloud('c', 1)]).map((f) => f.name), [
      'c',
      'a.jpg',
    ]);
  });

  test('a phone photo is a media file with no place in the cloud', () async {
    final phone = timeline(_Source([photo('a', may3, video: true)]), {});
    await phone.load();
    final file = phone.files.single;
    expect(file.isMedia, isTrue);
    expect(file.isVideo, isTrue);
    expect(file.path, [CloudFile.phoneRoot, 'a']);
    expect(file.readOnly, isTrue, reason: 'no cloud action applies to it');
    // The day is the one the photo was taken on the phone, not in UTC.
    expect(file.captureDay, dayOf(2025, 5, 3));
    expect(file.timelineDate, DateTime(2025, 5, 3));
  });

  test('says whether a reading changed what is shown', () async {
    final source = _Source([photo('a', may1)]);
    final phone = timeline(source, {});
    expect(await phone.load(), isTrue);
    expect(await phone.load(), isFalse, reason: 'nothing changed');
    source.all = [photo('a', may1), photo('b', may3)];
    expect(await phone.load(), isTrue);
  });

  test('shows nothing when the phone library may not be read', () async {
    final source = _Source([photo('a', may1)]);
    final phone = timeline(source, {});
    await phone.load();
    expect(phone.files, hasLength(1));
    source.permissionIs = LibraryPermission.denied;
    expect(await phone.load(), isTrue);
    expect(phone.files, isEmpty);
  });

  test('with no phone it passes the cloud lists straight through', () async {
    final phone = PhoneTimeline.none();
    final files = [cloud('a', 5)];
    final days = [const TimelineDay(5, 1)];
    expect(await phone.load(), isFalse);
    expect(identical(phone.all.items(files), files), isTrue);
    expect(identical(phone.all.days(days), days), isTrue);
    expect(phone.all.dayLoaded(9, (_) => false), isFalse);
    expect(phone.thumbnails, isNull);
  });

  group('merged with the cloud', () {
    late PhoneTimeline phone;
    setUp(() async {
      phone = timeline(
        _Source([photo('p1', may1), photo('p2', may1), photo('p3', may3)]),
        {},
      );
      await phone.load();
    });

    test('lists both, and keeps the same list while nothing changes', () {
      final files = [cloud('c', dayOf(2025, 5, 1))];
      final merged = phone.all.items(files);
      expect(merged.map((f) => f.name), ['c', 'p3.jpg', 'p1.jpg', 'p2.jpg']);
      expect(identical(phone.all.items(files), merged), isTrue);
      expect(identical(phone.all.items([...files]), merged), isFalse);
    });

    test('adds the phone to each day and gives a phone-only day its own', () {
      final cloudDays = [
        TimelineDay(dayOf(2025, 5, 3), 4),
        TimelineDay(dayOf(2025, 4, 28), 2),
      ];
      // May 1 has no cloud photos; May 3 has four.
      final merged = phone.all.days(cloudDays);
      expect(
        [for (final d in merged) (d.id, d.count)],
        [
          (dayOf(2025, 5, 3), 5),
          (dayOf(2025, 5, 1), 2),
          (dayOf(2025, 4, 28), 2),
        ],
      );
      expect(identical(phone.all.days(cloudDays), merged), isTrue);
    });

    test(
      'a day only the phone has is whole, a cloud day is up to the cloud',
      () {
        phone.all.days([TimelineDay(dayOf(2025, 5, 3), 4)]);
        expect(phone.all.dayLoaded(dayOf(2025, 5, 1), (_) => false), isTrue);
        expect(phone.all.dayLoaded(dayOf(2025, 5, 3), (_) => false), isFalse);
        expect(phone.all.dayLoaded(dayOf(2025, 5, 3), (_) => true), isTrue);
      },
    );

    test('the Timeline puts each photo in the section of its day', () {
      final cloudDays = [
        TimelineDay(dayOf(2025, 5, 3), 1),
        TimelineDay(dayOf(2025, 4, 28), 1),
      ];
      final files = [
        cloud('c1', dayOf(2025, 5, 3)),
        cloud('c2', dayOf(2025, 4, 28)),
      ];
      final sections = buildTimelineSections(
        media: phone.all.items(files),
        indexedDays: phone.all.days(cloudDays),
        dayLoaded: (day) => phone.all.dayLoaded(day, (_) => true),
        dayNeedsRefresh: (_) => false,
        labelFor: (date) => '${date!.month}/${date.day}',
      );
      expect(
        [
          for (final s in sections)
            '${s.label}: ${s.files.map((f) => f.name).join(',')} (${s.expected})',
        ],
        ['5/3: c1,p3.jpg (2)', '5/1: p1.jpg,p2.jpg (2)', '4/28: c2 (1)'],
      );
      expect(sections.every((s) => s.pending.isEmpty), isTrue);
    });
  });
}
