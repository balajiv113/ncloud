import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/provider_factory.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_account.dart';
import 'package:ncloud/providers/nextcloud/nextcloud_client.dart';

void main() {
  test('each entry point receives an independently owned provider', () {
    final foreground = createCloudBackend();
    final background = createCloudBackend();
    expect(foreground, isA<NextcloudClient>());
    expect(background, isA<NextcloudClient>());
    expect(identical(foreground, background), isFalse);
    foreground.close();
    background.close();
  });

  test('legacy sessions preserve account and storage identity', () {
    final legacy = jsonEncode({
      'server': 'https://cloud.example',
      'loginName': 'alice',
      'appPassword': 'test-password',
      'userId': 'uid',
      'displayName': 'Alice',
      'photoRoot': ['Photos'],
    });
    final account = restoreCloudAccount(legacy) as NextcloudAccount;
    expect(account.storageKey, 'https://cloud.example|uid');
    expect(account.photoRoot, ['Photos']);
    expect(account.loginName, 'alice');
    expect(
      restoreCloudAccount(account.encode()).storageKey,
      account.storageKey,
    );
  });

  test('unknown providers are not treated as Nextcloud', () {
    expect(
      () => restoreCloudAccount(jsonEncode({'provider': 'unknown'})),
      throwsFormatException,
    );
  });
}
