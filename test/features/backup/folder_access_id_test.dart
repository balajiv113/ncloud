import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/features/backup/platform/folder_access.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(
    () => messenger.setMockMethodCallHandler(NativeFolderAccess.channel, null),
  );

  test(
    'a file is opened by the id its listing gave, not searched for by name',
    () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(NativeFolderAccess.channel, (
        call,
      ) async {
        calls.add(call);
        if (call.method == 'list') {
          return [
            {
              'name': 'IMG_1.jpg',
              'directory': false,
              'size': 10,
              'modified': 1700000000000,
              'id': 'primary:DCIM/Camera/IMG_1.jpg',
            },
            {'name': 'old.jpg', 'directory': false, 'size': 5, 'modified': 1},
          ];
        }
        return '/tmp/staged.part';
      });
      final access = NativeFolderAccess();
      final listed = await access.list('tree', ['Camera']);
      expect(listed.first.id, 'primary:DCIM/Camera/IMG_1.jpg');
      expect(listed.last.id, isNull, reason: 'older providers give no id');

      await access.export('tree', ['Camera', 'IMG_1.jpg'], listed.first);
      expect(calls.last.arguments['id'], 'primary:DCIM/Camera/IMG_1.jpg');
      await access.export('tree', ['Camera', 'old.jpg'], listed.last);
      expect((calls.last.arguments as Map).containsKey('id'), isFalse);
    },
  );

  group('the fingerprint taken while copying', () {
    const sha = 'da39a3ee5e6b4b0d3255bfef95601890afd80709';
    const entry = DeviceEntry('a.jpg', false, 1, 1);

    void answer(Object? result) => messenger.setMockMethodCallHandler(
      NativeFolderAccess.channel,
      (call) async => call.method == 'discard' ? null : result,
    );

    test(
      'is remembered with the copy and forgotten when it is discarded',
      () async {
        answer({'path': '/tmp/a.part', 'sha1': sha});
        final access = NativeFolderAccess();
        final file = await access.export('tree', ['a.jpg'], entry);
        expect(file.path, '/tmp/a.part');
        expect(await access.checksumOf(file), sha);
        await access.discard(file);
        expect(await access.checksumOf(file), isNull);
      },
    );

    test('is ignored when it is not a SHA-1', () async {
      answer({'path': '/tmp/b.part', 'sha1': 'not-a-checksum'});
      final access = NativeFolderAccess();
      final file = await access.export('tree', ['a.jpg'], entry);
      expect(await access.checksumOf(file), isNull);
    });

    test('a plain path still works and has no fingerprint', () async {
      answer('/tmp/c.part');
      final access = NativeFolderAccess();
      final file = await access.export('tree', ['a.jpg'], entry);
      expect(file.path, '/tmp/c.part');
      expect(await access.checksumOf(file), isNull);
    });
  });
}
