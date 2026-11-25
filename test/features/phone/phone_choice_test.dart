import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/backup/engine/file_mark.dart';
import 'package:ncloud/features/backup/model/folder_pair.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/phone/phone_choice.dart';
import 'package:ncloud/features/phone/phone_library.dart';
import 'package:ncloud/features/phone/phone_photo.dart';
import 'package:ncloud/features/phone/phone_photos_tile.dart';
import 'package:ncloud/features/phone/phone_source.dart';
import 'package:ncloud/features/phone/phone_timeline.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' show account;

class _Source implements PhoneSource {
  LibraryPermission granted = LibraryPermission.granted;
  final requests = <String>[];
  final StreamController<void> library = StreamController<void>.broadcast();

  @override
  Future<LibraryPermission> permission() async => granted;
  @override
  Future<LibraryPermission> request() async {
    requests.add('asked');
    return granted;
  }

  @override
  Future<List<PhonePhoto>> photos() async => [
    PhonePhoto(
      id: 'a',
      name: 'a.jpg',
      size: 10,
      taken: DateTime(2025, 5, 1),
      isVideo: false,
    ),
  ];
  @override
  Future<Uint8List?> thumbnail(String id, int size) async => null;
  @override
  Future<File> original(String id) async => throw UnimplementedError();
  @override
  Stream<void> get changes => library.stream;
}

FolderPair get pair => FolderPair(
  id: 'p',
  account: 'a|b',
  name: 'p',
  folder: const DeviceFolder('t', 'Camera', 'camera'),
  remote: const ['Backup'],
);

PhoneTimeline overlay(PhoneSource source, PhoneChoiceStore choices) =>
    PhoneTimeline(
      choices: choices,
      source: source,
      library: PhoneLibrary(
        source: source,
        pairs: () async => [pair],
        marks: (_) async => const <FileMark>[],
      ),
    );

void main() {
  group('the choice', () {
    test(
      'the first time, the user is asked, and yes shows the photos',
      () async {
        final source = _Source();
        final choices = MemoryPhoneChoiceStore(PhoneChoice.ask);
        final phone = overlay(source, choices);
        expect(await phone.load(), isTrue);
        expect(source.requests, ['asked']);
        expect(choices.choice, PhoneChoice.show);
        expect(phone.files, hasLength(1));
        await phone.load();
        expect(
          source.requests,
          hasLength(1),
          reason: 'asked once, not every time',
        );
      },
    );

    test(
      'the first time, no turns them off, and the user is not asked again',
      () async {
        final source = _Source()..granted = LibraryPermission.denied;
        final choices = MemoryPhoneChoiceStore(PhoneChoice.ask);
        final phone = overlay(source, choices);
        expect(await phone.load(), isFalse);
        expect(choices.choice, PhoneChoice.hide);
        expect(phone.files, isEmpty);
        await phone.load();
        expect(source.requests, hasLength(1));
      },
    );

    test('turned off, nothing is read or shown', () async {
      final source = _Source();
      final phone = overlay(source, MemoryPhoneChoiceStore(PhoneChoice.hide));
      expect(await phone.load(), isFalse);
      expect(phone.files, isEmpty);
      expect(source.requests, isEmpty);
    });

    test(
      'turned on from settings asks the phone, and says if it was refused',
      () async {
        final source = _Source()..granted = LibraryPermission.denied;
        final choices = MemoryPhoneChoiceStore(PhoneChoice.hide);
        final phone = overlay(source, choices);
        expect(await phone.setShown(true), isFalse);
        expect(await phone.isShown(), isFalse);
        source.granted = LibraryPermission.granted;
        expect(await phone.setShown(true), isTrue);
        expect(await phone.isShown(), isTrue);
        expect(await phone.setShown(false), isFalse);
        expect(choices.choice, PhoneChoice.hide);
      },
    );

    test('shown, but the phone has taken the permission back', () async {
      final source = _Source();
      final phone = overlay(source, MemoryPhoneChoiceStore(PhoneChoice.show));
      await phone.load();
      expect(phone.files, hasLength(1));
      source.granted = LibraryPermission.denied;
      expect(await phone.load(), isTrue);
      expect(phone.files, isEmpty);
    });
  });

  group('live refresh', () {
    testWidgets('a change in the library is told once it has settled', (
      tester,
    ) async {
      final source = _Source();
      final phone = overlay(source, MemoryPhoneChoiceStore());
      var told = 0;
      phone.watch(() => told++);
      for (var i = 0; i < 5; i++) {
        source.library.add(null);
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(told, 0, reason: 'still changing');
      await tester.pump(const Duration(seconds: 3));
      expect(told, 1);
      phone.dispose();
      source.library.add(null);
      await tester.pump(const Duration(seconds: 5));
      expect(told, 1, reason: 'stopped listening');
    });

    test('the controller redraws when the library changes', () async {
      final source = _Source();
      final controller = AppController(
        store: MemoryStore(),
        client: NextcloudClient(
          transport: MockClient((_) async => http.Response('', 404)),
        ),
        phoneTimeline: overlay(source, MemoryPhoneChoiceStore()),
      )..account = account;
      addTearDown(controller.dispose);
      await controller.refreshPhone();
      expect(controller.phone.files, hasLength(1));
    });
  });

  testWidgets('the setting turns the photos on and off', (tester) async {
    final source = _Source();
    final choices = MemoryPhoneChoiceStore(PhoneChoice.hide);
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((_) async => http.Response('', 404)),
      ),
      phoneTimeline: overlay(source, choices),
    )..account = account;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhonePhotosTile(controller: controller)),
      ),
    );
    await tester.pump();
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(choices.choice, PhoneChoice.show);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isTrue,
    );
    expect(controller.phone.files, hasLength(1));
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(choices.choice, PhoneChoice.hide);
    expect(controller.phone.files, isEmpty);
  });

  testWidgets('a refused permission says where to allow it', (tester) async {
    final source = _Source()..granted = LibraryPermission.denied;
    final controller = AppController(
      store: MemoryStore(),
      client: NextcloudClient(
        transport: MockClient((_) async => http.Response('', 404)),
      ),
      phoneTimeline: overlay(source, MemoryPhoneChoiceStore(PhoneChoice.hide)),
    )..account = account;
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: PhonePhotosTile(controller: controller)),
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(find.textContaining('phone\'s settings'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
      isFalse,
    );
  });
}
