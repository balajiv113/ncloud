import 'package:flutter/painting.dart';
import 'dart:io';
import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/engine/file_mark.dart';
import 'package:ncloud/features/backup/model/backup_state.dart';
import 'package:ncloud/features/backup/model/folder_pair.dart';
import 'package:ncloud/features/backup/platform/device_library.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';
import 'package:ncloud/features/phone/phone_library.dart';
import 'package:ncloud/features/phone/phone_photo.dart';
import 'package:ncloud/features/phone/phone_source.dart';
import 'package:ncloud/features/phone/phone_states.dart';

PhonePhoto photo(
  String id, {
  String? name,
  int size = 10,
  int day = 1,
  bool video = false,
}) => PhonePhoto(
  id: id,
  name: name ?? '$id.jpg',
  size: size,
  taken: DateTime(2025, 1, day),
  isVideo: video,
  album: 'Camera',
);

FileMark mark(
  String? id,
  BackupState state, {
  String name = 'x.jpg',
  int size = 10,
}) => FileMark(id: id, name: name, size: size, state: state);

FolderPair pair(String id) => FolderPair(
  id: id,
  account: 'a|b',
  name: id,
  folder: const DeviceFolder('t', 'Camera', 'camera'),
  remote: const ['Backup'],
);

class _Source implements PhoneSource {
  _Source(this.all);
  final List<PhonePhoto> all;

  @override
  Future<LibraryPermission> permission() async => LibraryPermission.granted;
  @override
  Future<LibraryPermission> request() async => LibraryPermission.granted;
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

void main() {
  group('PhoneStates', () {
    test('a photo no backup knows is left out', () {
      expect(PhoneStates(const []).of(photo('a')), BackupState.leftOut);
    });

    test('finds a photo by the phone id', () {
      final states = PhoneStates([mark('a', BackupState.backedUp)]);
      expect(states.of(photo('a')), BackupState.backedUp);
      expect(states.of(photo('b')), BackupState.leftOut);
    });

    test('falls back to the name and size when the source has no ids', () {
      final states = PhoneStates([
        mark(null, BackupState.backedUp, name: 'IMG_1.jpg', size: 500),
      ]);
      expect(
        states.of(photo('image:9', name: 'IMG_1.jpg', size: 500)),
        BackupState.backedUp,
      );
      expect(
        states.of(photo('image:9', name: 'IMG_1.jpg', size: 501)),
        BackupState.leftOut,
      );
    });

    test('never matches on a name alone when the size is not known', () {
      final states = PhoneStates([
        mark(null, BackupState.backedUp, name: 'IMG_1.jpg', size: -1),
      ]);
      expect(
        states.of(photo('x', name: 'IMG_1.jpg', size: -1)),
        BackupState.leftOut,
      );
    });

    test('the furthest along of several backups counts', () {
      final states = PhoneStates([
        mark('a', BackupState.failed),
        mark('a', BackupState.backedUp),
        mark('a', BackupState.waiting),
        mark('b', BackupState.failed),
        mark('b', BackupState.waiting),
      ]);
      expect(states.of(photo('a')), BackupState.backedUp);
      expect(states.of(photo('b')), BackupState.waiting);
    });
  });

  group('PhoneLibrary', () {
    test('gives every photo its state, newest first', () async {
      final library = PhoneLibrary(
        source: _Source([
          photo('old', day: 1),
          photo('new', day: 20),
          photo('mid', day: 10),
          photo('lonely', day: 5),
        ]),
        pairs: () async => [pair('one'), pair('two')],
        marks: (pair) async => switch (pair.id) {
          'one' => [
            mark('old', BackupState.backedUp),
            mark('mid', BackupState.waiting),
          ],
          _ => [
            mark('new', BackupState.failed),
            mark('mid', BackupState.failed),
          ],
        },
      );
      final entries = await library.entries();
      expect(
        [for (final e in entries) e.photo.id],
        ['new', 'mid', 'lonely', 'old'],
      );
      expect(
        [for (final e in entries) e.state],
        [
          BackupState.failed,
          BackupState.waiting,
          BackupState.leftOut,
          BackupState.backedUp,
        ],
      );
    });

    test('with no backups every photo is left out', () async {
      final library = PhoneLibrary(
        source: _Source([photo('a'), photo('b')]),
        pairs: () async => const [],
        marks: (_) async => throw StateError('no backup to ask'),
      );
      expect(
        [for (final e in await library.entries()) e.state],
        [BackupState.leftOut, BackupState.leftOut],
      );
    });
  });

  group('NativePhoneSource', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(
      () =>
          messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null),
    );

    test('reads photos with their taken date and type', () async {
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        switch (call.method) {
          case 'mediaAccess':
            return {'status': 'granted'};
          case 'mediaList':
            return [
              {
                'id': 'image:1',
                'name': 'a.jpg',
                'size': 100,
                'modified': 2000,
                'taken': 1000,
                'contentType': 'image/jpeg',
                'folder': 'DCIM/Camera',
              },
              {
                'id': 'video:2',
                'name': 'b.mp4',
                'size': 900,
                'modified': 5000,
                'contentType': 'video/mp4',
                'folder': '',
              },
            ];
        }
        return null;
      });
      final source = NativePhoneSource(NativeFolderAccess());
      expect(await source.permission(), LibraryPermission.granted);
      final photos = await source.photos();
      expect(photos.map((p) => p.id), ['image:1', 'video:2']);
      expect(photos[0].taken.millisecondsSinceEpoch, 1000);
      expect(photos[0].isVideo, isFalse);
      // No taken date from the phone: the modified date stands in.
      expect(photos[1].taken.millisecondsSinceEpoch, 5000);
      expect(photos[1].isVideo, isTrue);
    });
  });

  group('thumbnails', () {
    test(
      'the native source asks the phone for a picture of one photo',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        addTearDown(
          () => messenger.setMockMethodCallHandler(
            NativeFolderAccess.channel,
            null,
          ),
        );
        final asked = <Object?>[];
        messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
          call,
        ) async {
          asked.add(call.arguments);
          return call.arguments['id'] == 'gone'
              ? throw PlatformException(code: 'media_thumbnail')
              : Uint8List.fromList([0xFF, 0xD8, 1]);
        });
        final source = NativePhoneSource(NativeFolderAccess());
        expect(await source.thumbnail('image:1', 200), [0xFF, 0xD8, 1]);
        expect(asked.single, {'id': 'image:1', 'size': 200});
        expect(await source.thumbnail('gone', 200), isNull);
      },
    );
  });

  group('showing and playing without a copy', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    tearDown(
      () =>
          messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null),
    );

    List<Object?> answer(Object? Function(MethodCall call) reply) {
      final asked = <Object?>[];
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        asked.add([call.method, call.arguments]);
        return reply(call);
      });
      return asked;
    }

    test(
      'a photo read where it is on the phone is drawn from that file',
      () async {
        answer((_) => {'path': '/storage/emulated/0/DCIM/Camera/a.jpg'});
        final image = await NativePhoneSource(
          NativeFolderAccess(),
        ).image('image:1');
        expect(image, isA<FileImage>());
        expect(
          (image! as FileImage).file.path,
          '/storage/emulated/0/DCIM/Camera/a.jpg',
        );
      },
    );

    test('a photo given as image data is drawn from memory', () async {
      answer(
        (_) => {
          'bytes': Uint8List.fromList([1, 2, 3]),
        },
      );
      final image = await NativePhoneSource(NativeFolderAccess()).image('A1');
      expect(image, isA<MemoryImage>());
      expect((image! as MemoryImage).bytes, [1, 2, 3]);
    });

    test('a photo the phone cannot give is none', () async {
      answer((_) => null);
      expect(await NativePhoneSource(NativeFolderAccess()).image('x'), isNull);
    });

    test(
      'a video is played where it is when the phone allows, with nothing to remove',
      () async {
        final asked = answer((_) => '/storage/emulated/0/DCIM/Camera/v.mp4');
        final video = await NativePhoneSource(
          NativeFolderAccess(),
        ).video('video:2');
        expect(video.file.path, '/storage/emulated/0/DCIM/Camera/v.mp4');
        expect(video.temporary, isFalse);
        expect(asked.single, [
          'mediaPlayable',
          {'id': 'video:2'},
        ]);
        await video.release(); // the phone's own file is left alone
      },
    );

    test(
      'a video the phone will not let be played in place is copied',
      () async {
        final asked = answer(
          (call) => call.method == 'mediaPlayable'
              ? null
              : {'path': '/cache/original.part'},
        );
        final video = await NativePhoneSource(
          NativeFolderAccess(),
        ).video('video:2');
        expect(video.file.path, '/cache/original.part');
        expect(video.temporary, isTrue);
        expect(asked.map((a) => (a! as List).first), [
          'mediaPlayable',
          'mediaOriginal',
        ]);
      },
    );

    test(
      'a copy is asked for straight away when playing in place failed',
      () async {
        final asked = answer((_) => {'path': '/cache/original.part'});
        final video = await NativePhoneSource(
          NativeFolderAccess(),
        ).video('video:2', copy: true);
        expect(video.temporary, isTrue);
        expect(asked.map((a) => (a! as List).first), ['mediaOriginal']);
      },
    );

    test(
      'a copy is removed when released, and the phone\'s own file never is',
      () async {
        final dir = Directory.systemTemp.createTempSync('video');
        addTearDown(() => dir.deleteSync(recursive: true));
        final copy = File('${dir.path}/copy.part')..writeAsStringSync('x');
        final own = File('${dir.path}/own.mp4')..writeAsStringSync('x');
        await PhoneVideo(copy, temporary: true).release();
        await PhoneVideo(own, temporary: false).release();
        expect(copy.existsSync(), isFalse);
        expect(own.existsSync(), isTrue);
        await PhoneVideo(
          copy,
          temporary: true,
        ).release(); // already gone: no error
      },
    );
  });
}
