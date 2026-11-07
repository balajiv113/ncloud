import 'dart:convert';

import '../core/cloud/cloud_backend.dart';
import '../models.dart';
import '../providers/nextcloud/nextcloud_account.dart';
import '../providers/nextcloud/nextcloud_client.dart';

CloudBackend createCloudBackend() => NextcloudClient();

Account restoreCloudAccount(String value) {
  final data = (jsonDecode(value) as Map).cast<String, dynamic>();
  return switch (data['provider']) {
    null || 'nextcloud' => NextcloudAccount.decode(data),
    _ => throw const FormatException('Unsupported cloud account provider.'),
  };
}
