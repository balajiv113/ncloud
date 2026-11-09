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
}
