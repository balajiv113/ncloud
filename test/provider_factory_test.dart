import 'package:flutter_test/flutter_test.dart';
import 'package:ncloud/app/provider_factory.dart';
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
}
