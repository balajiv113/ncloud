import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/app_controller.dart';
import 'package:ncloud/core/cloud/cloud_backend.dart';
import 'package:ncloud/models.dart';

import '../../app_test.dart' show MemoryStore;
import '../../nextcloud_client_test.dart' as fixtures;
import 'backup_controller_test.dart' show CloudFolders;

class _Counting extends CloudFolders {
  int listings = 0;

  @override
  Future<FolderListing> listFolder(
    Account account,
    List<String> path, {
    bool metadataOnly = false,
    bool optional = false,
  }) {
    listings++;
    return super.listFolder(
      account,
      path,
      metadataOnly: metadataOnly,
      optional: optional,
    );
  }
}

void main() {
  test('a backup that put files on the server reloads what is shown', () async {
    final cloud = _Counting()..folders.add('Backup');
    final app = AppController(store: MemoryStore(), client: cloud)
      ..account = fixtures.account;
    addTearDown(app.dispose);
    expect(app.backup.onServerChanged, isNotNull);
    await app.openFolder(
      CloudFile(path: const ['Backup'], name: 'Backup', isDirectory: true),
    );
    final before = cloud.listings;
    app.backup.onServerChanged!();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(cloud.listings, greaterThan(before));
  });
}
