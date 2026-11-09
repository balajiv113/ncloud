import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/features/files/file_actions.dart';
import 'package:ncloud/models.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' as fixtures;
import '../backup/backup_controller_test.dart' show CloudFolders;

void main() {
  testWidgets('a folder\'s menu shows Delete on a small phone screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final app = AppController(store: MemoryStore(), client: CloudFolders())
      ..account = fixtures.account;
    addTearDown(app.dispose);
    final folder = CloudFile(
      path: const ['Backup', 'Camera Roll'],
      name: 'Camera Roll',
      isDirectory: true,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => fileActions(context, app, folder),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final delete = find.text('Delete from server');
    expect(delete, findsOneWidget);
    expect(tester.getRect(delete).bottom, lessThanOrEqualTo(640));
    await tester.tap(delete);
    await tester.pumpAndSettle();
    expect(find.text('Delete Camera Roll?'), findsOneWidget);
  });
}
