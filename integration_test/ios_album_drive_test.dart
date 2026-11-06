import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:ncloud/folder_sync.dart';

import '../test/drive_navigation_test.dart' as drive;
import '../test/folder_sync_test.dart' show CloudFolders;
import '../test/nextcloud_client_test.dart' show account;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  drive.main();

  testWidgets(
    'real iOS PhotoKit exports album originals and repeated uploads reuse receipts',
    (tester) async {
      expect(Platform.isIOS, isTrue);
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: Text('Testing whole-album backup')),
        ),
      );
      await tester.runAsync(() async {
        final access = NativeFolderAccess();
        final albums = await access.albums();
        DeviceFolder? selected;
        DeviceEntry? original;
        for (final album in albums) {
          final entries = await access.list(album.token, []);
          final probes = entries.where(
            (entry) => entry.name.startsWith('ncloud-probe'),
          );
          if (probes.isNotEmpty) {
            selected = album;
            original = probes.first;
            break;
          }
        }
        expect(
          selected,
          isNotNull,
          reason: 'CI must seed a photo and grant Full Photos Access.',
        );
        final folder = selected!;
        final source = original!;
        expect(folder.kind, DeviceSourceKind.photoAlbum);
        expect(source.size, -1);
        expect(source.revision, isNotEmpty);
        final staged = await access.export(folder.token, [source.name], source);
        late List<int> bytes;
        try {
          bytes = await staged.readAsBytes();
          expect(bytes, isNotEmpty);
        } finally {
          await access.discard(staged);
        }
        final temp = await Directory.systemTemp.createTemp(
          'ncloud-ios-integration-',
        );
        final journal = SyncJournal(path: '${temp.path}/journal.sqlite3');
        final cloud = CloudFolders();
        final sync = FolderSyncController(
          client: cloud,
          account: () => account,
          access: access,
          journal: journal,
        );
        try {
          await sync.load();
          await sync.add(
            'Simulator album',
            folder,
            ['Backup'],
            SyncMode.backup,
            false,
            wifiOnly: false,
          );
          final pair = sync.pairs.single;
          await sync.run(pair);
          expect(sync.error, isNull);
          expect(
            cloud.files[['Backup', folder.name, source.name].join('/')]!.$1,
            bytes,
          );
          final uploaded = cloud.uploads;
          expect(uploaded, greaterThan(0));
          await sync.run(pair);
          expect(sync.error, isNull);
          expect(cloud.uploads, uploaded);
          expect(
            await journal.receipt(pair.id, 'local', [source.name]),
            isNotNull,
          );
        } finally {
          await sync.disconnect();
          sync.dispose();
          await journal.close();
          await temp.delete(recursive: true);
        }
      });
    },
  );
}
