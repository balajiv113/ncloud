import '../cloud_backend.dart';
import '../providers/nextcloud/nextcloud_client.dart';

CloudBackend createCloudBackend() => NextcloudClient();
